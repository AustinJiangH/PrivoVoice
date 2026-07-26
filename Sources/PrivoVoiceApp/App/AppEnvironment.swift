// The shared object graph: one instance owns every PrivoVoiceKit service, used by
// both the SwiftUI scenes and the AppKit delegate. A single `@MainActor`
// singleton keeps the SwiftUI side and the AppKit side (hotkey, HUD, paste)
// looking at the same state.

import Foundation
import Observation
import PrivoVoiceKit

@MainActor
@Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    let settings: AppSettings
    let store: ModelStore
    let downloader: ModelDownloader
    let appState: AppState
    let dictation: DictationController
    let telemetry: Telemetry
    let route = Router()

    private init() {
        let settings = AppSettings()
        let store = ModelStore(settings: settings)
        self.settings = settings
        self.store = store
        self.downloader = ModelDownloader(store: store, settings: settings)
        let appState = AppState()
        self.appState = appState

        // Usage totals for the Dashboard (local) + opt-in reporting (off by default).
        let telemetry = Telemetry(settings: settings)
        self.telemetry = telemetry

        // Formatter downloads use the same optional HF token as model downloads.
        FormatterStore.shared.tokenProvider = { [weak settings] in settings?.huggingFaceToken }

        // Two-process: transcription runs in the sidecar, isolated from the UI.
        let engine = HelperProcessDictationEngine(helperURL: Self.resolveHelperURL())
        self.dictation = DictationController(
            appState: appState, settings: settings, store: store, engine: engine,
            telemetry: telemetry)

        // First-run landing: Models when nothing is installed yet, else the
        // Dashboard. Set once here so an explicit menu-bar jump isn't clobbered.
        route.selection = store.installedIDs.isEmpty ? .models : .dashboard
    }

    /// Locate the `PrivoVoiceHelper` sidecar: an env override (dev), else a
    /// sibling of the running executable — which holds for both a bundled `.app`
    /// (Contents/MacOS/) and a `swift run` build (.build/<config>/).
    private static func resolveHelperURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["PRIVOVOICE_HELPER_PATH"] {
            return URL(fileURLWithPath: override)
        }
        let dir = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? ".").deletingLastPathComponent()
        return dir.appendingPathComponent("PrivoVoiceHelper")
    }
}
