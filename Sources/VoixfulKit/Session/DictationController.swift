// The dictation session orchestrator — the reusable heart of the app.
//
// Given the selected model, it builds a `Transcribing` module, captures the mic,
// drives a `VoixfulAnalyzer`, and publishes phase / level / partial text into
// `AppState`. `start()` on push-to-talk key-down, `stop()` on key-up; the final
// transcript is handed to `onFinalTranscript` (the app layer pastes/copies it).
//
// UI-agnostic and platform-portable: the macOS app and a future iOS app both
// drive it the same way.

import AVFoundation
import Foundation
import Observation
import VoixfulSpeech
import VoixfulEngine

@MainActor
@Observable
public final class DictationController {
    public let appState: AppState
    private let settings: AppSettings
    private let store: ModelStore

    /// Delivered the final transcript when a session completes (non-empty only).
    public var onFinalTranscript: ((String) -> Void)?

    /// Bundle of everything one live session owns, so `stop()` can tear it down.
    private struct Session: Sendable {
        let capture: AudioCapture
        let analyzer: VoixfulAnalyzer
        let startTask: Task<Void, Error>
        let reader: Task<String?, Never>
        let levelPoll: Task<Void, Never>
    }
    private var session: Session?

    public init(appState: AppState, settings: AppSettings, store: ModelStore) {
        self.appState = appState
        self.settings = settings
        self.store = store
    }

    public var isRunning: Bool { session != nil }

    /// A model is selected AND installed — a precondition for `start()`.
    public var canStart: Bool { resolveModel() != nil }

    // MARK: Lifecycle

    /// Begin a push-to-talk session (key-down). No-op if one is already running.
    public func start() {
        guard session == nil else { return }
        guard let (spec, url) = resolveModel() else {
            appState.lastError = "Select and install a model in the Models tab first."
            return
        }

        // Build the transcriber first so a bad model fails before we open the mic.
        let transcriber: any Transcribing
        do {
            transcriber = try TranscriberFactory.makeLive(
                modelURL: url, backend: spec.backend,
                locale: Locale(identifier: settings.localeIdentifier))
        } catch {
            appState.lastError = "Could not load \(spec.displayName): \(error)"
            return
        }

        let capture = AudioCapture()
        let stream = capture.makeStream()
        do {
            try capture.start()
        } catch {
            appState.lastError = "\(error)"
            return
        }

        let analyzer = VoixfulAnalyzer(modules: [transcriber])
        appState.lastError = nil
        appState.setPhase(.listening)

        // Read results: partials refresh the HUD; the last final is the payload.
        let reader = Task { @MainActor [appState] () -> String? in
            var lastFinal: String?
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal { lastFinal = text }
                    else { appState.setPartial(text) }
                }
            } catch {
                appState.lastError = "Transcription error: \(error)"
            }
            return lastFinal
        }

        // Load the model + start pumping audio. Kept as a handle so `stop()` can
        // wait for cold-start to finish before finalizing.
        let startTask = Task { try await analyzer.start(inputSequence: stream) }

        // Poll the mic level ~20×/s for the HUD meter.
        let levelPoll = Task { @MainActor [appState] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                appState.setLevel(capture.sampleLevel())
            }
        }

        session = Session(
            capture: capture, analyzer: analyzer,
            startTask: startTask, reader: reader, levelPoll: levelPoll)
    }

    /// End the session (key-up): stop the mic, finalize, deliver the transcript.
    public func stop() {
        guard let s = session else { return }
        session = nil
        appState.setPhase(.transcribing)
        s.levelPoll.cancel()
        s.capture.stop()   // finishes the input stream so the analyzer pump drains

        Task { @MainActor in
            do {
                try await s.startTask.value   // ensure cold-start finished
                try await s.analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                // Cold-start (model load) or finalize failed. `prepare()` throwing
                // never closes the transcriber's result stream, so cancel the
                // analyzer to finish it — otherwise the reader below awaits a
                // stream that never ends and this task (and the UI) wedges.
                appState.lastError = "Dictation failed: \(error)"
                await s.analyzer.cancelAndFinishNow()
            }
            let final = (await s.reader.value ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            appState.setPhase(.idle)
            appState.reset()
            // Preserve the previous transcript on a no-speech / failed tap.
            if !final.isEmpty {
                appState.commitTranscript(final)
                onFinalTranscript?(final)
            }
        }
    }

    /// Hard-cancel without finalizing (e.g. app quit).
    public func cancel() {
        guard let s = session else { return }
        session = nil
        s.levelPoll.cancel()
        s.reader.cancel()
        s.startTask.cancel()
        s.capture.stop()
        Task { await s.analyzer.cancelAndFinishNow() }
        appState.setPhase(.idle)
        appState.reset()
    }

    // MARK: Helpers

    private func resolveModel() -> (ModelSpec, URL)? {
        guard let id = settings.selectedModelID,
              let spec = ModelCatalog.spec(id: id),
              store.isInstalled(spec) else { return nil }
        return (spec, store.installURL(for: spec))
    }
}
