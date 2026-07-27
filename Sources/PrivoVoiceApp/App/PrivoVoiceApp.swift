// PrivoVoice — a macOS push-to-talk dictation app built on the PrivoVoice core.
//
// Scenes: a main Window (sidebar → Settings / Models) and a MenuBarExtra status
// item. The floating HUD, global hotkey, and paste live in `AppDelegate` (AppKit).

import AppKit
import SwiftUI
import PrivoVoiceKit

@main
struct PrivoVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var env = AppEnvironment.shared

    var body: some Scene {
        Window("PrivoVoice", id: WindowID.main) {
            RootView()
                .environment(env)
                .tint(AppTheme.accent)   // wood accent inherited by all controls
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 860, height: 560)

        MenuBarExtra {
            MenuBarContent()
                .environment(env)
                .tint(AppTheme.accent)
        } label: {
            MenuBarIconLabel(phase: env.appState.phase)
        }
    }
}

/// Menu-bar glyph: the PrivoVoice bird/shield logo at rest, SF Symbols while a
/// dictation is in flight (mic → ellipsis → sparkles) for live phase feedback.
private struct MenuBarIconLabel: View {
    let phase: DictationPhase

    var body: some View {
        if phase == .idle, let logo = MenuBarIconLabel.logo {
            Image(nsImage: logo)
        } else {
            Image(systemName: phase.menuBarSymbol)
        }
    }

    /// The brand SVG as a template image: template rendering keys off the alpha
    /// channel only, so the colored artwork becomes a monochrome mark that
    /// adapts to light/dark menu bars and the highlighted (pressed) state.
    /// Built once — NSImage keeps the vector rep, so it stays crisp on Retina.
    private static let logo: NSImage? = {
        guard
            let url = Bundle.module.url(forResource: "MenuBarLogo", withExtension: "svg"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        image.size = NSSize(width: 18, height: 18)   // standard status-item glyph size
        image.isTemplate = true
        return image
    }()
}

enum WindowID {
    static let main = "privovoice-main"
}

extension DictationPhase {
    /// Menu-bar glyph reflecting the global status.
    var menuBarSymbol: String {
        switch self {
        case .idle: return "waveform"
        case .listening: return "mic.fill"
        case .transcribing: return "ellipsis"
        case .polishing: return "sparkles"
        }
    }
}
