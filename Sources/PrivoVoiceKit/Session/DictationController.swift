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

    /// The installed formatter model directory when the final transcript should
    /// be polished, or `nil` to skip. Injectable so tests can exercise the
    /// polish path without a real `FormatterStore` install.
    var formatterModelPath: () -> String? = {
        FormatterStore.shared.isInstalled ? FormatterStore.shared.installDirectory.path : nil
    }
    /// How long `stop()` waits for the formatter before falling back to the raw
    /// transcript. Injectable for tests.
    var formatTimeoutSeconds: Double = 60

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
    /// Bumped by `cancel()`; the stop-task compares it before delivering so a
    /// cancel during the finalize/polish window drops that utterance instead
    /// of letting a late commit/paste overlap the next session.
    private var sessionEpoch = 0
    /// Model path (+ options) the engine was last asked to pre-warm the
    /// formatter for — debounces `warmFormatterIfNeeded` (re-warming is
    /// harmless but pointless). Cleared by `unloadFormatterIfIdle()` so a
    /// re-enable re-warms.
    private var warmedFormatterPath: String?
    private var warmedFormatterOptions: FormatterOptions?
    /// True whenever the engine may hold a resident formatter (a warm-up was
    /// sent or a polish ran) — debounces `unloadFormatterIfIdle`, whose
    /// trigger re-fires on unrelated install-phase changes.
    private var formatterMaybeResident = false

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

        // A cancel() during this task's finalize/polish window bumps the epoch;
        // the checks below then drop the utterance (cancel already reset the
        // published state) instead of committing/pasting it late.
        let epoch = sessionEpoch
        Task { @MainActor in
            _ = await session.run?.value          // let forwarding drain
            let raw = ((try? await engine.end()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Optionally polish the final transcript through the formatter LLM.
            // Best-effort with a hard timeout: any failure delivers the raw
            // transcript. The RAW text still drives telemetry below.
            var final = raw
            if !raw.isEmpty, settings.formatFinalTranscript, sessionEpoch == epoch,
               let modelPath = formatterModelPath() {
                appState.setPhase(.polishing)
                // Capability toggles are read at format time so mid-session
                // Settings changes apply to the very next utterance.
                let options = FormatterOptions(
                    removesFillers: settings.formatterRemovesFillers,
                    formatsLists: settings.formatterFormatsLists,
                    appliesCorrections: settings.formatterAppliesCorrections)
                formatterMaybeResident = true   // the engine just (cold-)loaded it
                final = await Self.polished(raw, engine: engine, modelPath: modelPath,
                                            options: options,
                                            timeoutSeconds: formatTimeoutSeconds)
                final = final.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard sessionEpoch == epoch else { return }   // cancelled mid-finalize
            appState.setPhase(.idle)
            appState.reset()
            finalizing = false    // now a new press may begin
            // Preserve the previous transcript on a no-speech / failed tap.
            if !final.isEmpty {
                // Optionally prepend a separating space so consecutive dictations
                // don't run together. The RAW `raw` still drives telemetry — the
                // separator isn't a word and formatting must not change stats.
                let delivered = settings.autoSpacing ? Self.separated(final) : final
                appState.commitTranscript(delivered)
                onFinalTranscript?(delivered)
                // Best-effort usage recording — never gates the transcript.
                let seconds = session.sampleRate > 0
                    ? Double(session.framesFed) / session.sampleRate : 0
                telemetry?.record(seconds: seconds, words: Self.wordCount(raw),
                                  modelID: settings.selectedModelID)
            }
        }
    }

    /// Run the engine's transcript formatter, racing a timeout; the raw `text`
    /// wins on any failure, timeout, or empty result.
    ///
    /// The group's implicit drain waits for BOTH children, so this only
    /// returns at ~`timeoutSeconds` because the engines' `format` is
    /// cancellation-responsive: `cancelAll()` makes the losing format child
    /// throw promptly (helper: fails the pending IPC wait; in-process: stops
    /// the token loop) instead of running to completion unobserved.
    nonisolated static func polished(
        _ text: String, engine: any DictationEngine, modelPath: String,
        options: FormatterOptions, timeoutSeconds: Double
    ) async -> String {
        let result = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                try? await engine.format(text: text, modelPath: modelPath, options: options)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeoutSeconds) * 1_000_000_000))
                return nil
            }
            // First finisher wins: the formatted text, or nil on error/timeout.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let result, !result.isEmpty else { return text }
        return result
    }

    /// Ask the engine to pre-load the formatter LLM (fire-and-forget) so the
    /// first formatted dictation doesn't pay the ~2 s cold model load on top of
    /// the user's transcript. Only meaningful when transcript formatting is ON
    /// and the model is installed; a no-op otherwise, and debounced per model
    /// path. Call at quiet moments only — app startup, the formatting setting
    /// turning on, a formatter download completing — NEVER per-dictation (the
    /// sidecar's request loop is serial; at launch the race with a first
    /// dictation is acceptable, it costs no more than today's cold format).
    public func warmFormatterIfNeeded() {
        guard settings.formatFinalTranscript, let path = formatterModelPath() else { return }
        // Warm with the user's real capability toggles so the prompt-prefix
        // cache is anchored for the options the first format will actually use.
        let options = FormatterOptions(
            removesFillers: settings.formatterRemovesFillers,
            formatsLists: settings.formatterFormatsLists,
            appliesCorrections: settings.formatterAppliesCorrections)
        guard warmedFormatterPath != path || warmedFormatterOptions != options else { return }
        warmedFormatterPath = path
        warmedFormatterOptions = options
        formatterMaybeResident = true
        let engine = self.engine
        Task { await engine.warmFormatter(modelPath: path, options: options) }
    }

    /// Counterpart of `warmFormatterIfNeeded`: ask the engine to drop the
    /// resident formatter (~1 GB) — called when formatting turns OFF or the
    /// model is removed. Skipped while a session is active/finalizing (the
    /// formatter may be mid-use; the next state-change trigger retries at a
    /// quiet moment) and debounced while nothing can be resident. Clears the
    /// warm debounce so a later re-enable re-warms.
    public func unloadFormatterIfIdle() {
        guard active == nil, !finalizing else { return }
        guard formatterMaybeResident else { return }
        formatterMaybeResident = false
        warmedFormatterPath = nil
        warmedFormatterOptions = nil
        let engine = self.engine
        Task { await engine.unloadFormatter() }
    }

    /// Hard-cancel without finalizing (e.g. app quit) — including a released
    /// utterance still in its finalize/polish window: the epoch bump makes the
    /// in-flight stop-task drop the transcript instead of committing it late,
    /// and `engine.cancel()` unblocks a pending finalize/format promptly.
    public func cancel() {
        guard active != nil || finalizing else { return }
        sessionEpoch += 1
        finalizing = false
        if let session = active {
            active = nil
            session.stopRequested = true
            session.run?.cancel()   // hard abort: dropping the tail is fine here
            session.capture.stop()
        }
        let engine = self.engine
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

    /// Prepend a single separating space unless the text already starts with
    /// whitespace or is empty — so back-to-back dictations don't run together.
    /// Multi-line text (a formatted numbered list) gets a newline instead, so
    /// item 1 doesn't glue onto the previous line's prose. Idempotent:
    /// `separated("")` == "" and text that already leads with whitespace is
    /// returned unchanged.
    nonisolated static func separated(_ text: String) -> String {
        guard let first = text.first else { return text }
        if first.isWhitespace { return text }
        return (text.contains("\n") ? "\n" : " ") + text
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
