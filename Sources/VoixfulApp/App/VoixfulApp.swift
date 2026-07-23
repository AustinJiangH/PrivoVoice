// Voixful — a macOS push-to-talk dictation app built on the Voixful core.
//
// Scenes: a main Window (sidebar → Settings / Models) and a MenuBarExtra status
// item. The floating HUD, global hotkey, and paste live in `AppDelegate` (AppKit).

import SwiftUI
import VoixfulKit

@main
struct VoixfulApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var env = AppEnvironment.shared

    var body: some Scene {
        Window("Voixful", id: WindowID.main) {
            RootView()
                .environment(env)
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 860, height: 560)

        MenuBarExtra {
            MenuBarContent()
                .environment(env)
        } label: {
            Image(systemName: env.appState.phase.menuBarSymbol)
        }
    }
}

enum WindowID {
    static let main = "voixful-main"
}

extension DictationPhase {
    /// Menu-bar glyph reflecting the global status.
    var menuBarSymbol: String {
        switch self {
        case .idle: return "waveform"
        case .listening: return "mic.fill"
        case .transcribing: return "ellipsis"
        }
    }
}
