// The system-tray menu: current status, a shortcut into the window, and Quit.

import SwiftUI
import AppKit
import PrivoVoiceKit

struct MenuBarContent: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Status line.
        Label(statusText, systemImage: env.appState.phase.menuBarSymbol)
            .disabled(true)

        if let spec = selectedSpec {
            Text("Model: \(spec.displayName)")
                .disabled(true)
        } else {
            Text("No model selected")
                .disabled(true)
        }

        Divider()

        Button("Open PrivoVoice…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: WindowID.main)
        }
        .keyboardShortcut("o")

        Button("Settings") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: WindowID.main)
            env.route.select(.settings)
        }

        Divider()

        Button("Quit PrivoVoice") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusText: String {
        env.appState.phase.label
    }

    private var selectedSpec: ModelSpec? {
        env.settings.selectedModelID.flatMap(ModelCatalog.spec(id:))
    }
}
