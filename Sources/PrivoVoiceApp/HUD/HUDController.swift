// The floating status HUD: two click-through, non-activating panels on the
// active screen —
//   • the notch island, pinned to the top edge, which grows out of the camera
//     notch like a Dynamic Island (or out of the top edge on a screen without
//     one) and shows the recording status;
//   • the live-transcript panel, at the top or bottom of the screen per
//     Settings, while live transcription is on. Its content view is the
//     system's `NSGlassEffectView`, so the window itself is Liquid Glass
//     (sampling the desktop behind it, with the system shadow) and is sized
//     to the text.
// Shown while listening/transcribing; on idle both animate away and the panels
// are ordered out once that has played. Reacts to `AppState.phase` via
// observation.

import AppKit
import SwiftUI
import Observation
import PrivoVoiceKit

/// Island state plus the screen geometry it morphs from. Owned by
/// `HUDController`, read by `HUDView`.
@MainActor
@Observable
final class HUDPresentation {
    /// Island expanded (out of the notch) vs collapsed (tucked into it).
    var isOpen = false
    var notch = NotchMetrics.fallback
}

/// The camera housing the island attaches to, in points.
struct NotchMetrics: Equatable {
    /// Width of the camera housing — the gap between the island's two wings.
    var width: CGFloat
    /// Height of the housing / menu bar — the island's top row.
    var height: CGFloat
    /// A real notch. Without one the island collapses to nothing at the top
    /// edge instead of to the notch's silhouette.
    var hasNotch: Bool

    /// A screen without a notch: a narrow virtual gap, menu-bar-height row.
    static let fallback = NotchMetrics(width: 24, height: 28, hasNotch: false)

    init(width: CGFloat, height: CGFloat, hasNotch: Bool) {
        self.width = width
        self.height = height
        self.hasNotch = hasNotch
    }

    init(screen: NSScreen) {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            self.init(width: max(0, screen.frame.width - left.width - right.width),
                      height: screen.safeAreaInsets.top, hasNotch: true)
        } else {
            // Menu bar height (0 when it auto-hides) → keep a sensible row.
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            self.init(width: Self.fallback.width,
                      height: menuBar > 0 ? menuBar : Self.fallback.height, hasNotch: false)
        }
    }
}

/// AppKit nudges windows out of the menu-bar strip when they're ordered in or
/// moved ("constrained" to the screen's visible area) — which dropped the
/// island below the menu bar so it seemed to slide out from under it. The
/// HUD deliberately overlaps the menu bar, so keep the frame exactly as set.
private final class TopEdgePanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Liquid Glass draws its full look (refraction, specular rim, vibrancy) only
/// while its window has the *active appearance*, which AppKit grants only to
/// the key/main window of the frontmost app. A non-activating HUD panel of an
/// accessory app never gets it, so its glass renders flat and white. There is
/// no public switch (`NSGlassEffectView` has no `state`), so this calls
/// NSWindow's private `_setForceMainAppearance:`: the window *looks* main
/// without becoming main or key, so it never takes focus. Returns false if
/// the method is gone (callers then fall back to a public material).
@MainActor
enum GlassActiveAppearance {
    private static let setter = NSSelectorFromString("_setForceMainAppearance:")

    @discardableResult
    static func force(_ window: NSWindow) -> Bool {
        guard window.responds(to: setter) else { return false }
        // Not KVC-compliant; call through the method's implementation.
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(window.method(for: setter), to: Setter.self)(window, setter, true)
        return true
    }
}

@MainActor
final class HUDController {
    private let appState: AppState
    private let settings: AppSettings
    private let presentation = HUDPresentation()
    private let islandPanel: NSPanel
    private let transcriptPanel: NSPanel
    /// Orders the panels out once the closing animations have finished;
    /// cancelled if a new session starts first.
    private var hideTask: Task<Void, Never>?
    /// The transcript's current height (reported by its SwiftUI content) and
    /// the frame it rests at on screen; the panel is fitted to these.
    private var transcriptHeight: CGFloat = 48
    /// The text's own latest height. During a session the panel only grows
    /// to fit it, never shrinks: the rolling 50-word window keeps re-wrapping
    /// (4 lines, 5, 4, …) and following that made the glass bounce.
    private var transcriptContentHeight: CGFloat = 48
    /// The panel's Liquid Glass and the hosted transcript, restyled per
    /// Settings each time the panel opens (nil glass = public fallback).
    private var transcriptGlass: NSGlassEffectView?
    private var transcriptHost: NSView?
    private var transcriptEdge: TranscriptPosition = .top
    private var transcriptAnchor = NSRect.zero

    // A generous transparent canvas; the island is anchored to its top edge
    // and only as big as it needs, so the empty area is invisible and
    // click-through.
    static let islandSize = NSSize(width: 560, height: 80)
    static let transcriptWidth: CGFloat = 420
    static let transcriptCornerRadius: CGFloat = 22
    /// Gap between the transcript and the menu bar / Dock.
    private static let transcriptMargin: CGFloat = 8
    /// How far the transcript slides in from its edge.
    private static let transcriptSlide: CGFloat = 16
    /// Long enough for the closing springs in the views to settle.
    private static let collapseDuration: Duration = .milliseconds(450)

    init(appState: AppState, settings: AppSettings) {
        self.appState = appState
        self.settings = settings

        islandPanel = Self.makePanel(TopEdgePanel.self, size: Self.islandSize)
        // Above the menu bar, so the island can cover the strip around the notch.
        islandPanel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        islandPanel.contentView = Self.host(
            HUDView(appState: appState, presentation: presentation), size: Self.islandSize)

        let transcriptSize = NSSize(width: Self.transcriptWidth, height: transcriptHeight)
        transcriptPanel = Self.makePanel(NSPanel.self, size: transcriptSize)
        transcriptPanel.level = .statusBar
        // The shadow follows the glass's rounded shape (the window is clear).
        transcriptPanel.hasShadow = true
        // Before the glass joins the window, so it starts out active.
        let glassIsActive = GlassActiveAppearance.force(transcriptPanel)

        observePhase()
        // After init: the hosted view reports its height through `self`.
        let host = Self.host(
            TranscriptPanelView(appState: appState, settings: settings, onDarkMaterial: !glassIsActive,
                                width: Self.transcriptWidth) { [weak self] height in
                self?.transcriptHeightChanged(height)
            },
            size: transcriptSize)
        host.autoresizingMask = [.width, .height]
        transcriptHost = host
        if glassIsActive {
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: transcriptSize))
            glass.cornerRadius = Self.transcriptCornerRadius
            glass.contentView = host
            transcriptGlass = glass
            transcriptPanel.contentView = glass
            applyGlassStyle()
        } else {
            transcriptPanel.contentView = Self.fallbackMaterial(size: transcriptSize, content: host)
        }
    }

    /// Settings → Transcript glass:
    ///   • clear — see-through `.clear` glass. It has no adaptive light/dark
    ///     behavior, so (per Apple's guidance for clear glass) it's dimmed with
    ///     a dark tint and the text is white, pinned to dark appearance.
    ///   • adaptive — the standard `.regular` glass: follows System Settings →
    ///     Appearance → Liquid Glass and flips light/dark with what's behind
    ///     it, telling the text via NSAppearance (so no appearance override).
    private func applyGlassStyle() {
        guard let transcriptGlass else { return }
        switch settings.transcriptGlass {
        case .clear:
            transcriptGlass.style = .clear
            transcriptGlass.tintColor = NSColor.black.withAlphaComponent(0.28)
            transcriptHost?.appearance = NSAppearance(named: .darkAqua)
        case .adaptive:
            transcriptGlass.style = .regular
            transcriptGlass.tintColor = nil
            transcriptHost?.appearance = nil
        }
    }

    /// If the active-appearance override is unavailable: always-active
    /// behind-window vibrancy (frosted, not Liquid Glass, but never flat).
    private static func fallbackMaterial(size: NSSize, content: NSView) -> NSView {
        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        let r = transcriptCornerRadius, edge = r * 2 + 1
        let mask = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        mask.resizingMode = .stretch
        fx.maskImage = mask
        fx.addSubview(content)
        return fx
    }

    private static func makePanel(_ type: NSPanel.Type, size: NSSize) -> NSPanel {
        let panel = type.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    private static func host(_ view: some View, size: NSSize) -> NSView {
        let host = NSHostingView(rootView: view.tint(AppTheme.accent))
        host.frame = NSRect(origin: .zero, size: size)
        // On a notched display the window's top safe-area inset covers the
        // menu-bar strip; SwiftUI would push the island down below it. The
        // island must start AT the top edge to grow out of the notch.
        host.safeAreaRegions = []
        // The controller sizes the panels; don't let SwiftUI constrain them.
        host.sizingOptions = []
        return host
    }

    /// Re-arm observation of `phase` and reflect it in panel visibility.
    private func observePhase() {
        withObservationTracking {
            _ = appState.phase
        } onChange: {
            Task { @MainActor in
                self.updateVisibility()
                self.observePhase()
            }
        }
        updateVisibility()
    }

    private func updateVisibility() {
        if appState.phase.isActive {
            hideTask?.cancel()
            hideTask = nil
            guard !presentation.isOpen else { return }
            if !islandPanel.isVisible {
                // Start tucked into this screen's notch, then open on the next
                // tick so SwiftUI animates it out.
                reposition()
                islandPanel.orderFrontRegardless()
            }
            if settings.showLiveTranscription { showTranscript() }
            Task { @MainActor in
                guard self.appState.phase.isActive else { return }
                self.presentation.isOpen = true
            }
        } else {
            presentation.isOpen = false
            hideTranscript()
            hideTask?.cancel()
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: Self.collapseDuration)
                guard !Task.isCancelled, !self.appState.phase.isActive else { return }
                self.islandPanel.orderOut(nil)
                self.transcriptPanel.orderOut(nil)
            }
        }
    }

    /// Place the panels on the screen containing the mouse (falls back to the
    /// main screen): the island hangs from the top-center (the notch is
    /// centered on it); the transcript rests just under the menu bar or just
    /// above the Dock.
    private func reposition() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main else { return }
        presentation.notch = NotchMetrics(screen: screen)

        let frame = screen.frame
        islandPanel.setFrame(NSRect(x: frame.midX - Self.islandSize.width / 2,
                                    y: frame.maxY - Self.islandSize.height,
                                    width: Self.islandSize.width, height: Self.islandSize.height),
                             display: true)

        // `visibleFrame` already excludes the menu bar (as tall as the
        // notch/island row) and the Dock.
        transcriptEdge = settings.transcriptPosition
        transcriptAnchor = screen.visibleFrame
    }

    // MARK: Transcript panel

    /// Where the transcript rests for its current height: pinned to its edge,
    /// growing away from it.
    private var transcriptFrame: NSRect {
        let w = Self.transcriptWidth, h = transcriptHeight
        let y = transcriptEdge == .top
            ? transcriptAnchor.maxY - h - Self.transcriptMargin
            : transcriptAnchor.minY + Self.transcriptMargin
        return NSRect(x: transcriptAnchor.midX - w / 2, y: y, width: w, height: h)
    }

    /// The resting frame nudged toward its screen edge — where it slides from.
    private var transcriptOffscreenFrame: NSRect {
        transcriptFrame.offsetBy(dx: 0, dy: transcriptEdge == .top ? Self.transcriptSlide : -Self.transcriptSlide)
    }

    /// Slide + fade the glass window in from its edge.
    private func showTranscript() {
        if !transcriptPanel.isVisible || transcriptPanel.alphaValue < 1 {
            if !transcriptPanel.isVisible {
                // A new session starts at the text's own size again.
                transcriptHeight = transcriptContentHeight
                GlassActiveAppearance.force(transcriptPanel)
                applyGlassStyle()
                transcriptPanel.alphaValue = 0
                transcriptPanel.setFrame(transcriptOffscreenFrame, display: true)
                transcriptPanel.orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                transcriptPanel.animator().alphaValue = 1
                transcriptPanel.animator().setFrame(transcriptFrame, display: true)
            }
        }
    }

    /// Slide + fade it back toward its edge; ordered out with the island.
    private func hideTranscript() {
        guard transcriptPanel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            transcriptPanel.animator().alphaValue = 0
            transcriptPanel.animator().setFrame(transcriptOffscreenFrame, display: true)
        }
    }

    /// The text wrapped onto more lines: grow the glass to fit, keeping the
    /// edge it's pinned to fixed. Fewer lines leave it as is until the
    /// session ends (see `transcriptContentHeight`).
    private func transcriptHeightChanged(_ height: CGFloat) {
        let height = height.rounded(.up)
        guard height > 0 else { return }
        transcriptContentHeight = height
        let visible = transcriptPanel.isVisible && transcriptPanel.alphaValue > 0
        // Hidden: just track it; `showTranscript` resets to it.
        guard visible else { transcriptHeight = height; return }
        guard height > transcriptHeight else { return }
        transcriptHeight = height
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            transcriptPanel.animator().setFrame(transcriptFrame, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.transcriptPanel.invalidateShadow() }
        }
    }
}
