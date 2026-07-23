// AppKit glue: activation policy (menu-bar accessory), the floating HUD, the
// global push-to-talk hotkey, and delivering the finished transcript (paste +
// optional copy). All wired against the shared `AppEnvironment`.

import AppKit
import SwiftUI
import Observation
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
        monitor.onPermissionChange = { [weak self] in self?.updatePermissionStatus() }
        monitor.start()
        self.hotkey = monitor
        observeHotkeyChanges()
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

    /// Re-register the Carbon hotkey whenever the user changes the shortcut.
    private func observeHotkeyChanges() {
        let settings = AppEnvironment.shared.settings
        withObservationTracking {
            _ = settings.hotkey
        } onChange: {
            Task { @MainActor in
                self.hotkey?.refresh()
                self.updatePermissionStatus()
                self.observeHotkeyChanges()
            }
        }
    }

    /// Reflect hotkey registration + paste permission in the UI.
    private func updatePermissionStatus() {
        guard let hotkey else { return }
        let appState = AppEnvironment.shared.appState
        appState.setHotkeyActive(hotkey.isActive)
        appState.setPasteAuthorized(hotkey.canPaste)
        if !hotkey.isActive {
            appState.lastError = "Couldn't register the push-to-talk shortcut — pick a "
                + "key + modifier combo in Settings (a bare modifier like fn can't be used)."
        } else if !hotkey.canPaste {
            appState.lastError = "Grant Accessibility to Voixful in System Settings → Privacy "
                + "& Security so the transcript can be pasted at the cursor."
        } else if appState.lastError?.hasPrefix("Grant ") == true
                    || appState.lastError?.hasPrefix("Couldn't") == true {
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
