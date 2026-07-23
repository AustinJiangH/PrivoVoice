// AppKit glue: activation policy (menu-bar accessory), the floating HUD, the
// global push-to-talk hotkey, and delivering the finished transcript (paste +
// optional copy). All wired against the shared `AppEnvironment`.

import AppKit
import SwiftUI
import VoixfulKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkey: HotkeyMonitor?
    private var hud: HUDController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar app: no Dock icon. The main window still opens at launch.
        NSApp.setActivationPolicy(.accessory)

        let env = AppEnvironment.shared

        // Deliver the final transcript: paste at the cursor, optionally keeping
        // it on the clipboard.
        env.dictation.onFinalTranscript = { text in
            Paster.deliver(text, keepInClipboard: env.settings.autoCopy)
        }

        // Floating status HUD (top-center), driven by AppState.
        hud = HUDController(appState: env.appState)

        // Global push-to-talk.
        let monitor = HotkeyMonitor(settings: env.settings)
        monitor.onPress = { env.dictation.start() }
        monitor.onRelease = { env.dictation.stop() }
        monitor.start()
        self.hotkey = monitor
        updatePermissionStatus()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Re-scan so a model copied into the folder while we were in the
        // background shows up without a relaunch.
        AppEnvironment.shared.store.refresh()
        // Install the hotkey tap if the user just granted permission.
        hotkey?.retry()
        updatePermissionStatus()
    }

    /// Reflect the exact missing permission(s) in the UI, or clear our message.
    private func updatePermissionStatus() {
        guard let hotkey else { return }
        let appState = AppEnvironment.shared.appState
        if hotkey.isActive && hotkey.canPaste {
            if appState.lastError?.hasPrefix("Grant ") == true { appState.lastError = nil }
            return
        }
        var missing: [String] = []
        if !hotkey.isActive { missing.append("Input Monitoring") }
        if !hotkey.canPaste { missing.append("Accessibility") }
        appState.lastError = "Grant " + missing.joined(separator: " + ")
            + " to Voixful in System Settings → Privacy & Security. "
            + "It activates when you switch back to Voixful (relaunch if it doesn't)."
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppEnvironment.shared.dictation.cancel()
        hotkey?.stop()
    }

    // Keep running as a menu-bar app even when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
