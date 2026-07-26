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

        // Keep the sidecar's resident formatter in sync with the settings +
        // install state: pre-warm when transcript formatting is on and the
        // model is installed (startup, setting turning on, download
        // completing) so the first formatted dictation doesn't pay the ~2 s
        // cold model load; unload (~1 GB freed) when either side goes away.
        syncFormatterResidency()
    }

    /// Fire exactly one residency trigger for the current state — warm when
    /// formatting is on AND the model is installed, unload otherwise — then
    /// re-arm on every change of the formatting setting or the formatter
    /// install phase (Observation fires once per change, so each pass
    /// re-registers). Both sides are debounced/guarded in the controller, so
    /// re-fires for unrelated phase changes (e.g. download progress) are
    /// harmless.
    private func syncFormatterResidency() {
        if settings.formatFinalTranscript && FormatterStore.shared.isInstalled {
            dictation.warmFormatterIfNeeded()
        } else {
            dictation.unloadFormatterIfIdle()
        }
        withObservationTracking {
            _ = settings.formatFinalTranscript
            _ = FormatterStore.shared.phase
        } onChange: { [weak self] in
            Task { @MainActor in self?.syncFormatterResidency() }
        }
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
