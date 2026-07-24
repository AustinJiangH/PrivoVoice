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
    /// Records usage totals (local Dashboard) and, if opted in, opt-in telemetry.
    /// Optional so tests and the in-process/iOS path can omit it entirely; when
    /// nil, dictation behaves exactly as before. Recording is best-effort and
    /// never affects the transcription flow.
    private let telemetry: Telemetry?

    /// Delivered the final transcript when a session completes (non-empty only).
    public var onFinalTranscript: ((String) -> Void)?

    /// Everything one live session owns.
    private final class Session {
        let capture: any AudioCapturing
        /// Sample rate of the mono stream we feed the engine — used to convert
        /// the frames fed into a duration for the usage total.
        let sampleRate: Double
        var run: Task<Void, Never>?
        /// Total mono samples forwarded this utterance; frames ÷ sampleRate is
        /// the transcribed audio length.
        var framesFed: Int = 0
        /// Set by stop()/cancel() to short-circuit a session whose mic hasn't
        /// opened yet, without cancelling the forwarding task (which would drop
        /// the AsyncStream's buffered tail).
        var stopRequested = false
        init(capture: any AudioCapturing, sampleRate: Double) {
            self.capture = capture
            self.sampleRate = sampleRate
        }
    }
    private var active: Session?
    /// True while a released utterance is still finalizing (blocks a new start).
    private var finalizing = false

    public init(
        appState: AppState, settings: AppSettings, store: ModelStore,
        engine: any DictationEngine,
        makeCapture: @escaping @Sendable () -> any AudioCapturing = { AudioCapture() },
        telemetry: Telemetry? = nil
    ) {
        self.appState = appState
        self.settings = settings
        self.store = store
        self.engine = engine
        self.makeCapture = makeCapture
        self.telemetry = telemetry
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
        appState.startRecordingClock(limitSeconds: spec.maxAudioSeconds)
        appState.setPhase(.listening)

        let session = Session(capture: capture, sampleRate: format.sampleRate)
        active = session
        let engine = self.engine
        let appState = self.appState

        session.run = Task { @MainActor in
            do {
                try await engine.begin(
                    modelURL: url, backend: spec.backend, locale: locale, format: format,
                    onPartial: { text in
                        // Drop the engine's "[ preparing <model> … ]" warming
                        // notice — it's status, not transcript, and its length
                        // briefly expanded the live box. Filtered here so the
                        // engine stays untouched.
                        guard !Self.isStatusPartial(text) else { return }
                        Task { @MainActor in appState.setPartial(text) }
                    })
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
                session.framesFed += samples.count   // for the transcribed-length total
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
                // Best-effort usage recording — never gates the transcript.
                let seconds = session.sampleRate > 0
                    ? Double(session.framesFed) / session.sampleRate : 0
                telemetry?.record(seconds: seconds, words: Self.wordCount(final),
                                  modelID: settings.selectedModelID)
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

    /// Whitespace-delimited word count of a transcript, for the usage total.
    nonisolated static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// The live full-context transcriber emits a bracketed "[ preparing <model>
    /// … ]" warming notice as a partial while its first pass runs. That's status,
    /// not transcript — keep it out of the live HUD display.
    nonisolated static func isStatusPartial(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).hasPrefix("[ preparing")
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
