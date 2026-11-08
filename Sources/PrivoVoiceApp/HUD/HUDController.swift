// The floating status HUD: a click-through, non-activating panel pinned to the
// top edge of the active screen, where the HUD grows out of the camera notch
// like a Dynamic Island (or out of the top edge on a screen without one). Shown
// while listening/transcribing; on idle the island shrinks back into the notch
// and the panel is ordered out once that animation has played. Reacts to
// `AppState.phase` via observation.

import AppKit
import SwiftUI
import Observation
import PrivoVoiceKit

/// The screen-specific geometry the island morphs from, plus whether it's open.
/// Owned by `HUDController`, read by `HUDView`.
@MainActor
@Observable
final class HUDPresentation {
    /// Expanded (out of the notch) vs collapsed (tucked into it).
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

@MainActor
final class HUDController {
    private let appState: AppState
    private let settings: AppSettings
    private let presentation = HUDPresentation()
    private let panel: NSPanel
    /// Orders the panel out once the collapse animation has finished; cancelled
    /// if a new session starts first.
    private var hideTask: Task<Void, Never>?

    // A generous transparent canvas hanging from the top edge; the island is
    // top-anchored inside it and only as big as it needs, so the empty area is
    // invisible and click-through.
    static let size = NSSize(width: 560, height: 380)
    /// Long enough for the closing spring in `HUDView` to settle.
    private static let collapseDuration: Duration = .milliseconds(450)

    init(appState: AppState, settings: AppSettings) {
        self.appState = appState
        self.settings = settings

        panel = TopEdgePanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Above the menu bar, so the island can cover the strip around the notch.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingView(rootView: HUDView(
            appState: appState, settings: settings, presentation: presentation)
            .tint(AppTheme.accent))
        host.frame = NSRect(origin: .zero, size: Self.size)
        // On a notched display the window's top safe-area inset covers the
        // menu-bar strip; SwiftUI would push the island down below it. The
        // island must start AT the top edge to grow out of the notch.
        host.safeAreaRegions = []
        panel.contentView = host

        observePhase()
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
            if !panel.isVisible {
                // Start tucked into this screen's notch, then open on the next
                // tick so SwiftUI animates from the collapsed shape.
                reposition()
                panel.orderFrontRegardless()
            }
            Task { @MainActor in
                guard self.appState.phase.isActive else { return }
                self.presentation.isOpen = true
            }
        } else {
            presentation.isOpen = false
            hideTask?.cancel()
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: Self.collapseDuration)
                guard !Task.isCancelled, !self.appState.phase.isActive else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    /// Hang the canvas from the top-center of the screen containing the mouse
    /// (falls back to the main screen) — the notch is centered on it.
    private func reposition() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main else { return }
        presentation.notch = NotchMetrics(screen: screen)
        let frame = screen.frame
        panel.setFrame(NSRect(x: frame.midX - Self.size.width / 2,
                              y: frame.maxY - Self.size.height,
                              width: Self.size.width, height: Self.size.height),
                       display: true)
    }
}
