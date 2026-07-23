// The dictation session orchestrator — engine-agnostic.
//
// Owns the microphone, forwards mono audio + a level to an injected
// `DictationEngine` (in-process, or the sidecar in the macOS app), and publishes
// phase / level / partial text into `AppState`. `start()` on push-to-talk
// key-down, `stop()` on key-up; the final transcript is handed to
// `onFinalTranscript` (the app layer pastes/copies it).

import AVFoundation
import Foundation
import Observation
import VoixfulEngine

@MainActor
@Observable
public final class DictationController {
    public let appState: AppState
    private let settings: AppSettings
    private let store: ModelStore
    private let engine: any DictationEngine
    private let makeCapture: @Sendable () -> any AudioCapturing

    /// Delivered the final transcript when a session completes (non-empty only).
    public var onFinalTranscript: ((String) -> Void)?

    /// Everything one live session owns.
    private final class Session {
        let capture: any AudioCapturing
        var run: Task<Void, Never>?
        /// Set by stop()/cancel() to short-circuit a session whose mic hasn't
        /// opened yet, without cancelling the forwarding task (which would drop
        /// the AsyncStream's buffered tail).
        var stopRequested = false
        init(capture: any AudioCapturing) { self.capture = capture }
    }
    private var active: Session?
    /// True while a released utterance is still finalizing (blocks a new start).
    private var finalizing = false

    public init(
        appState: AppState, settings: AppSettings, store: ModelStore,
        engine: any DictationEngine,
        makeCapture: @escaping @Sendable () -> any AudioCapturing = { AudioCapture() }
    ) {
        self.appState = appState
        self.settings = settings
        self.store = store
        self.engine = engine
        self.makeCapture = makeCapture
    }

    public var isRunning: Bool { active != nil }

    /// A model is selected AND installed — a precondition for `start()`.
    public var canStart: Bool { resolveModel() != nil }

    // MARK: Lifecycle

    /// Begin a push-to-talk session (key-down). No-op if one is already running,
    /// or while the previous utterance is still finalizing — the resident engine
    /// handles one utterance at a time, so overlapping would corrupt both.
    public func start() {
        guard active == nil, !finalizing else { return }
        guard let (spec, url) = resolveModel() else {
            appState.lastError = "Select and install a model in the Models tab first."
            return
        }

        let capture = makeCapture()
        guard let inputFormat = capture.inputFormat() else {
            appState.lastError = "No microphone is configured."
            return
        }
        // We downmix to mono before feeding the engine.
        let format = AudioStreamFormat(sampleRate: inputFormat.sampleRate, channels: 1)
        let locale = Locale(identifier: settings.localeIdentifier)

        appState.lastError = nil
        appState.setPhase(.listening)

        let session = Session(capture: capture)
        active = session
        let engine = self.engine
        let appState = self.appState

        session.run = Task { @MainActor in
            do {
                try await engine.begin(
                    modelURL: url, backend: spec.backend, locale: locale, format: format,
                    onPartial: { text in Task { @MainActor in appState.setPartial(text) } })
            } catch {
                appState.lastError = "Could not start \(spec.displayName): \(error)"
                return
            }
            // A very quick tap may have already released before the mic opened —
            // signalled by `stopRequested` (NOT Task cancellation, which would make
            // the AsyncStream below drop its buffered tail).
            if session.stopRequested { return }

            let stream = capture.makeStream()
            do {
                try capture.start()
            } catch {
                appState.lastError = "\(error)"
                return
            }

            // Forward mic audio until the stream ends. stop() finishes the stream
            // (via capture.stop()); the AsyncStream still delivers every buffered
            // buffer before terminating, so the utterance tail is never dropped.
            for await input in stream {
                let (samples, peak) = Self.monoSamples(input.buffer)
                appState.setLevel(peak)
                await engine.feed(samples)
            }
        }
    }

    /// End the session (key-up): stop the mic, finalize, deliver the transcript.
    public func stop() {
        guard let session = active else { return }
        active = nil
        finalizing = true
        appState.setPhase(.transcribing)
        session.stopRequested = true   // short-circuits a not-yet-capturing session
        session.capture.stop()         // ends the stream so the forwarder drains
        // NB: do NOT cancel `session.run` — that would make the AsyncStream drop
        // its buffered tail. `capture.stop()` drains it cleanly.

        Task { @MainActor in
            _ = await session.run?.value          // let forwarding drain
            let final = ((try? await engine.end()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            appState.setPhase(.idle)
            appState.reset()
            finalizing = false    // now a new press may begin
            // Preserve the previous transcript on a no-speech / failed tap.
            if !final.isEmpty {
                appState.commitTranscript(final)
                onFinalTranscript?(final)
            }
        }
    }

    /// Hard-cancel without finalizing (e.g. app quit).
    public func cancel() {
        finalizing = false
        guard let session = active else { return }
        active = nil
        session.stopRequested = true
        session.run?.cancel()   // hard abort: dropping the tail is fine here
        session.capture.stop()
        Task { await engine.cancel() }
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

    /// Downmix all channels to mono and return the samples plus the peak (0…1).
    nonisolated static func monoSamples(_ buffer: AVAudioPCMBuffer) -> ([Float], Float) {
        let n = Int(buffer.frameLength)
        guard n > 0, let channels = buffer.floatChannelData else { return ([], 0) }
        let channelCount = Int(buffer.format.channelCount)
        var out = [Float](repeating: 0, count: n)
        var peak: Float = 0
        for i in 0..<n {
            var sum: Float = 0
            for c in 0..<channelCount { sum += channels[c][i] }
            let v = sum / Float(channelCount)
            out[i] = v
            peak = max(peak, abs(v))
        }
        return (out, min(1, peak))
    }
}
