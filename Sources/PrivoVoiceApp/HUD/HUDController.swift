// The floating status HUD: a small, click-through, non-activating panel pinned
// to the top-center of the active screen. Shown while listening/transcribing,
// ordered out when idle. Reacts to `AppState.phase` via observation.

import AppKit
import SwiftUI
import Observation
import PrivoVoiceKit

@MainActor
final class HUDController {
    private let appState: AppState
    private let settings: AppSettings
    private let panel: NSPanel

    // Fixed width; height is a generous transparent canvas — the SwiftUI content
    // is top-anchored and only as tall as it needs, so the empty area below is
    // invisible and click-through. Sized to fit the transcript box at full lines.
    private static let size = NSSize(width: 400, height: 380)

    init(appState: AppState, settings: AppSettings) {
        self.appState = appState
        self.settings = settings

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingView(rootView: HUDView(appState: appState, settings: settings)
            .tint(AppTheme.accent))
        host.frame = NSRect(origin: .zero, size: Self.size)
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
            reposition()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    /// Pin to the top-center of the screen containing the mouse (falls back to
    /// the main screen), just below the menu bar.
    private func reposition() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let x = visible.midX - Self.size.width / 2
        let y = visible.maxY - Self.size.height - 12
        panel.setFrame(NSRect(x: x, y: y, width: Self.size.width, height: Self.size.height), display: true)
    }
}
