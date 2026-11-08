// The floating status HUD: two click-through, non-activating panels on the
// active screen —
//   • the notch island, pinned to the top edge, which grows out of the camera
//     notch like a Dynamic Island (or out of the top edge on a screen without
//     one) and shows the recording status;
//   • the live-transcript panel (Liquid Glass), at the top or bottom of the
//     screen per Settings, while live transcription is on.
// Shown while listening/transcribing; on idle both animate away and the panels
// are ordered out once that has played. Reacts to `AppState.phase` via
// observation.

import AppKit
import SwiftUI
import Observation
import PrivoVoiceKit

/// What the two HUD panels show, plus the screen geometry the island morphs
/// from. Owned by `HUDController`, read by `HUDView` and `TranscriptPanelView`.
@MainActor
@Observable
final class HUDPresentation {
    /// Island expanded (out of the notch) vs collapsed (tucked into it).
    var isOpen = false
    var notch = NotchMetrics.fallback
    /// Transcript panel content shown (slid in) vs hidden.
    var showsTranscript = false
    /// Which screen edge the transcript panel sits on (fixed per session).
    var transcriptPosition: TranscriptPosition = .top
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

    // Generous transparent canvases; the content is anchored to one edge
    // inside each and only as big as it needs, so the empty area is invisible
    // and click-through.
    static let islandSize = NSSize(width: 560, height: 80)
    static let transcriptSize = NSSize(width: 440, height: 300)
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

        transcriptPanel = Self.makePanel(NSPanel.self, size: Self.transcriptSize)
        transcriptPanel.level = .statusBar
        transcriptPanel.contentView = Self.host(
            TranscriptPanelView(appState: appState, presentation: presentation),
            size: Self.transcriptSize)

        observePhase()
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
                // Start tucked into this screen's notch (transcript hidden),
                // then open on the next tick so SwiftUI animates both in.
                reposition()
                islandPanel.orderFrontRegardless()
                if settings.showLiveTranscription { transcriptPanel.orderFrontRegardless() }
            }
            Task { @MainActor in
                guard self.appState.phase.isActive else { return }
                self.presentation.isOpen = true
                self.presentation.showsTranscript = self.settings.showLiveTranscription
            }
        } else {
            presentation.isOpen = false
            presentation.showsTranscript = false
            hideTask?.cancel()
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: Self.collapseDuration)
                guard !Task.isCancelled, !self.appState.phase.isActive else { return }
                self.islandPanel.orderOut(nil)
                self.transcriptPanel.orderOut(nil)
            }
        }
    }

    /// Place both panels on the screen containing the mouse (falls back to the
    /// main screen): the island hangs from the top-center (the notch is
    /// centered on it); the transcript sits just under the menu bar or just
    /// above the Dock.
    private func reposition() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main else { return }
        presentation.notch = NotchMetrics(screen: screen)
        presentation.transcriptPosition = settings.transcriptPosition

        let frame = screen.frame
        islandPanel.setFrame(NSRect(x: frame.midX - Self.islandSize.width / 2,
                                    y: frame.maxY - Self.islandSize.height,
                                    width: Self.islandSize.width, height: Self.islandSize.height),
                             display: true)

        // Clear the island (as tall as the menu bar / notch) at the top; the
        // Dock is already outside `visibleFrame` at the bottom.
        let visible = screen.visibleFrame
        let size = Self.transcriptSize
        let y = settings.transcriptPosition == .top
            ? visible.maxY - size.height - 6
            : visible.minY + 6
        transcriptPanel.setFrame(NSRect(x: visible.midX - size.width / 2, y: y,
                                        width: size.width, height: size.height),
                                 display: true)
    }
}
