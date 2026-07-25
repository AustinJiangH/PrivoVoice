// The system-tray menu: quick navigation (Dashboard / Settings), the current
// status + model in use, and Quit.

import SwiftUI
import AppKit
import PrivoVoiceKit

struct MenuBarContent: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Dashboard") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: WindowID.main)
            env.route.select(.dashboard)
        }
        Button("Settings") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: WindowID.main)
            env.route.select(.settings)
        }

        Divider()

        // Informational, non-interactive: live status + the model in use.
        Label(env.appState.phase.label, systemImage: env.appState.phase.menuBarSymbol)
            .disabled(true)
        if let spec = selectedSpec {
            Text("Model: \(spec.displayName)")
                .disabled(true)
        } else {
            Text("No model selected")
                .disabled(true)
        }

        Divider()

        Button("Quit PrivoVoice") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var selectedSpec: ModelSpec? {
        env.settings.selectedModelID.flatMap(ModelCatalog.spec(id:))
    }
}
