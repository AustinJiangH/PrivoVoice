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

        if !monitor.isTrusted {
            env.appState.lastError = "Grant Accessibility & Input Monitoring permission to Voixful, "
                + "then relaunch, to enable the push-to-talk hotkey and paste."
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Re-scan so a model copied into the folder while we were in the
        // background shows up without a relaunch.
        AppEnvironment.shared.store.refresh()
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
