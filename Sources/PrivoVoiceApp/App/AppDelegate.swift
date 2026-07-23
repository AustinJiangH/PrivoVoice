// AppKit glue: activation policy (menu-bar accessory), the floating HUD, the
// global push-to-talk hotkey, and delivering the finished transcript (paste +
// optional copy). All wired against the shared `AppEnvironment`.

import AppKit
import SwiftUI
import PrivoVoiceKit

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
        monitor.onPermissionChange = { [weak self] in self?.updatePermissionStatus() }
        monitor.start()
        self.hotkey = monitor
        updatePermissionStatus()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Re-scan so a model copied into the folder while we were in the
        // background shows up without a relaunch.
        AppEnvironment.shared.store.refresh()
        // Re-check the paste (Accessibility) permission after a Settings visit.
        hotkey?.refresh()
        updatePermissionStatus()
    }

    /// Reflect the single Accessibility permission (hotkey tap + paste) in the UI.
    private func updatePermissionStatus() {
        guard let hotkey else { return }
        let appState = AppEnvironment.shared.appState
        appState.setHotkeyActive(hotkey.isActive)
        appState.setPasteAuthorized(hotkey.canPaste)
        if !hotkey.isActive {
            appState.lastError = "Grant Accessibility to PrivoVoice in System Settings → Privacy "
                + "& Security to enable the shortcut and pasting (no Input Monitoring needed)."
        } else if appState.lastError?.hasPrefix("Grant ") == true {
            appState.lastError = nil
        }
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
