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
import os
import VoixfulEngine
import VoixfulSpeech

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
    /// A press at least this long that yields no audio (or only digital
    /// silence) is reported as a microphone problem rather than dropped
    /// silently — shorter taps are normal no-speech taps. Injectable for tests.
    var silentMicMinSeconds: Double = 1.0

    /// Persisted diagnostics (`log show --predicate 'subsystem == "com.privovoice.app"'`),
    /// so a "nothing was transcribed" report can be traced after the fact.
    private static let log = Logger(subsystem: "com.privovoice.app", category: "dictation")

    /// Everything one live session owns.
    private final class Session {
        let capture: any AudioCapturing
        /// Sample rate of the mono stream we feed the engine — used to convert
        /// the frames fed into a duration for the usage total.
        let sampleRate: Double
        /// The model this session transcribes with (marked warm once it ends).
        var modelPath = ""
        var run: Task<Void, Never>?
        /// Total mono samples forwarded this utterance; frames ÷ sampleRate is
        /// the transcribed audio length.
        var framesFed: Int = 0
        /// Set by stop()/cancel() to short-circuit a session whose mic hasn't
        /// opened yet, without cancelling the forwarding task (which would drop
        /// the AsyncStream's buffered tail).
        var stopRequested = false
        /// The engine acknowledged `begin` — until then mic audio is held in
        /// the forwarder (the mic opens first so no speech is lost).
        var engineReady = false
        /// A start-up failure was already reported; skip the silent-mic check.
        var failed = false
        /// Mic buffers seen and their loudest sample — for the dead/silent-mic
        /// check at release and the diagnostics log.
        var buffersReceived = 0
        var maxPeak: Float = 0
        let pressedAt = Date()
        var releasedAt: Date?
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
    /// The model the engine has already loaded (a session or warm-up with it
    /// finished), so a session with it won't pay the cold load.
    private var warmModelPath: String?
    /// A background warm-up in flight (`warmUpModel`). A session that starts
    /// meanwhile opens the mic at once and begins after it.
    private var warmTask: Task<Void, Never>?
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
    /// Serializes the warm/unload sends: each send awaits the previous one,
    /// so they reach the engine in decision order. Two independent Tasks
    /// could otherwise arrive swapped — an unload overtaking a warm drops the
    /// model the user just asked for; a warm overtaking an unload resurrects
    /// ~1 GB nothing wants.
    private var residencyTask: Task<Void, Never>?

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
        appState.setNotice(nil)
        appState.startRecordingClock(limitSeconds: spec.maxAudioSeconds)
        appState.setModelWarming(url.path != warmModelPath)
        appState.setPhase(.listening)

        let session = Session(capture: capture, sampleRate: format.sampleRate)
        session.modelPath = url.path
        active = session
        let engine = self.engine
        let appState = self.appState
        let pendingWarm = warmTask

        session.run = Task { @MainActor in
            // A very quick tap may have already released before this task ran —
            // signalled by `stopRequested` (NOT Task cancellation, which would
            // make the AsyncStream below drop its buffered tail).
            if session.stopRequested { return }
            // Open the mic FIRST and hold its audio here until the engine is
            // ready: the engine may still be warming up, or (in the sidecar)
            // finishing a previous request, and waiting for it with the mic
            // closed silently lost everything said meanwhile — a flat meter
            // and an empty transcript on a short press.
            let stream = capture.makeStream()
            do {
                try capture.start()
            } catch {
                Self.log.error("mic failed to start: \(String(describing: error), privacy: .public)")
                session.failed = true
                appState.lastError = "\(error)"
                appState.setNotice("Mic unavailable")
                return
            }
            Self.log.notice("""
                mic open: \(format.sampleRate, privacy: .public) Hz, \
                model \(spec.id, privacy: .public), warming \(pendingWarm != nil, privacy: .public)
                """)

            let began = Task { @MainActor () -> Error? in
                // The model is still warming up in the background: begin once
                // the engine is free — it takes one utterance at a time.
                await pendingWarm?.value
                // Cancelled while waiting: never begin an engine session nobody ends.
                if Task.isCancelled { return CancellationError() }
                let t0 = Date()
                do {
                    try await engine.begin(
                        modelURL: url, backend: spec.backend, locale: locale, format: format,
                        onPartial: { text in
                            // Drop the engine's "[ preparing <model> … ]" warming
                            // notice — it's status, not transcript, and its length
                            // briefly expanded the live box. Filtered here so the
                            // engine stays untouched.
                            // (It does mean the model is loading, though.)
                            if Self.isStatusPartial(text) {
                                Task { @MainActor in appState.setModelWarming(true) }
                                return
                            }
                            // Real words: the model is up.
                            Task { @MainActor in
                                appState.setModelWarming(false)
                                appState.setPartial(text)
                            }
                        })
                } catch {
                    return error
                }
                Self.log.notice("engine ready after \(Date().timeIntervalSince(t0), format: .fixed(precision: 2), privacy: .public) s")
                session.engineReady = true
                return nil
            }

            // Forward mic audio until the stream ends. stop() finishes the stream
            // (via capture.stop()); the AsyncStream still delivers every buffered
            // buffer before terminating, so the utterance tail is never dropped.
            var held: [[Float]] = []
            for await input in stream {
                let (samples, peak) = Self.monoSamples(input.buffer)
                session.buffersReceived += 1
                session.maxPeak = max(session.maxPeak, peak)
                appState.setLevel(peak)
                if session.engineReady {
                    for chunk in held { await Self.feed(chunk, to: engine, session: session) }
                    held.removeAll()
                    await Self.feed(samples, to: engine, session: session)
                } else {
                    held.append(samples)
                }
            }
            // Released (or cancelled) — wait for the engine, then flush.
            if Task.isCancelled { began.cancel(); return }
            if let error = await began.value {
                Self.log.error("engine begin failed: \(String(describing: error), privacy: .public)")
                session.failed = true
                appState.lastError = "Could not start \(spec.displayName): \(error)"
                appState.setNotice("Couldn't start")
                return
            }
            for chunk in held { await Self.feed(chunk, to: engine, session: session) }
        }
    }

    /// Forward one mono chunk, counting it toward the transcribed length.
    private static func feed(_ samples: [Float], to engine: any DictationEngine,
                             session: Session) async {
        session.framesFed += samples.count
        await engine.feed(samples)
    }

    /// End the session (key-up): stop the mic, finalize, deliver the transcript.
    public func stop() {
        guard let session = active else { return }
        active = nil
        finalizing = true
        appState.setPhase(.transcribing)
        session.stopRequested = true   // short-circuits a not-yet-capturing session
        session.releasedAt = Date()
        session.capture.stop()         // ends the stream so the forwarder drains
        // NB: do NOT cancel `session.run` — that would make the AsyncStream drop
        // its buffered tail. `capture.stop()` drains it cleanly.

        // A cancel() during this task's finalize/polish window bumps the epoch;
        // the checks below then drop the utterance (cancel already reset the
        // published state) instead of committing/pasting it late.
        let epoch = sessionEpoch
        Task { @MainActor in
            _ = await session.run?.value          // let forwarding drain
            var ended: String?
            var endError: Error?
            do { ended = try await engine.end() } catch { endError = error }
            if ended != nil { warmModelPath = session.modelPath }
            appState.setModelWarming(false)
            let raw = (ended ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
            let held = (session.releasedAt ?? Date()).timeIntervalSince(session.pressedAt)
            let endNote = endError.map { ", end failed: \(String(describing: $0))" } ?? ""
            Self.log.notice("""
                released after \(held, format: .fixed(precision: 2), privacy: .public) s: \
                \(session.buffersReceived, privacy: .public) buffers, \
                peak \(session.maxPeak, format: .fixed(precision: 5), privacy: .public), \
                \(session.framesFed, privacy: .public) frames fed, \
                \(raw.count, privacy: .public) chars\(endNote, privacy: .public)
                """)
            // An empty result is normally a no-speech tap — but say so when the
            // mic or engine actually failed, instead of silently doing nothing.
            if final.isEmpty, !session.failed,
               let problem = Self.diagnose(heldSeconds: held, minSeconds: silentMicMinSeconds,
                                           buffers: session.buffersReceived,
                                           peak: session.maxPeak, endError: endError) {
                appState.lastError = problem.message
                appState.setNotice(problem.notice)
            }
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
            // The session is over — retry the residency decision a mid-session
            // settings change couldn't apply (see syncResidencyAfterSession).
            syncResidencyAfterSession()
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
        residencyTask = Task { [previous = residencyTask] in
            await previous?.value
            await engine.warmFormatter(modelPath: path, options: options)
        }
    }

    /// Counterpart of `warmFormatterIfNeeded`: ask the engine to drop the
    /// resident formatter (~1 GB) — called when formatting turns OFF or the
    /// model is removed. Skipped while a session is active/finalizing (the
    /// formatter may be mid-use; `syncResidencyAfterSession` retries the
    /// moment the session ends) and debounced while nothing can be resident.
    /// Clears the warm debounce so a later re-enable re-warms.
    public func unloadFormatterIfIdle() {
        guard active == nil, !finalizing else { return }
        guard formatterMaybeResident else { return }
        formatterMaybeResident = false
        warmedFormatterPath = nil
        warmedFormatterOptions = nil
        let engine = self.engine
        residencyTask = Task { [previous = residencyTask] in
            await previous?.value
            await engine.unloadFormatter()
        }
    }

    /// End-of-session residency sync, run whenever `finalizing` clears (the
    /// stop-task's completion path and `cancel()`). While a session was live,
    /// `unloadFormatterIfIdle` refused to touch a maybe-mid-use formatter —
    /// and nothing else retries at session end (the app's Observation trigger
    /// only fires on setting/install-phase changes), so a mid-session
    /// toggle-off or model removal would leave ~1 GB resident indefinitely.
    /// One decision, exactly one action: warm when formatting is on and the
    /// model is installed (debounced — normally a no-op), unload otherwise
    /// (debounced while nothing can be resident).
    private func syncResidencyAfterSession() {
        if settings.formatFinalTranscript, formatterModelPath() != nil {
            warmFormatterIfNeeded()
        } else {
            unloadFormatterIfIdle()
        }
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
        appState.setModelWarming(false)
        appState.setPhase(.idle)
        appState.reset()
        // `finalizing` just cleared without the stop-task's completion path —
        // this is the cancelled session's end-of-session residency retry.
        syncResidencyAfterSession()
    }

    /// Load the selected speech model in the background (at launch, or when
    /// the selection / installed models change) so the first dictation
    /// doesn't pay the cold load: a silent throwaway utterance through the
    /// engine. No-op while dictating, already warm, or already warming.
    public func warmUpModel() {
        guard active == nil, !finalizing, warmTask == nil,
              let (spec, url) = resolveModel(), url.path != warmModelPath else { return }
        let engine = self.engine
        let locale = Locale(identifier: settings.localeIdentifier)
        let sampleRate = 16_000.0
        warmTask = Task { @MainActor in
            defer { warmTask = nil }
            do {
                try await engine.begin(
                    modelURL: url, backend: spec.backend, locale: locale,
                    format: AudioStreamFormat(sampleRate: sampleRate, channels: 1),
                    onPartial: { _ in })
                await engine.feed([Float](repeating: 0, count: Int(sampleRate / 2)))
                _ = try await engine.end()
                warmModelPath = url.path
            } catch {
                // Best-effort: the first real dictation cold-loads as before.
            }
        }
    }

    // MARK: Helpers

    /// Below this peak a "live" mic is delivering digital silence — macOS does
    /// this when microphone access is denied, and a dead or muted device does
    /// too. A working mic's noise floor in a quiet room sits well above it.
    nonisolated static let silenceFloor: Float = 1e-4

    /// Why an utterance that produced no text failed, if it did: a short
    /// HUD notice plus the full message for Settings. `nil` for an ordinary
    /// no-speech tap.
    nonisolated static func diagnose(
        heldSeconds: Double, minSeconds: Double, buffers: Int, peak: Float, endError: Error?
    ) -> (notice: String, message: String)? {
        if let endError {
            return ("Engine failed", "Transcription failed: \(endError)")
        }
        guard heldSeconds >= minSeconds else { return nil }
        if buffers == 0 {
            return ("No mic audio",
                    "The microphone didn't deliver any audio. Check the input device in "
                    + "System Settings → Sound → Input.")
        }
        if peak < silenceFloor {
            return ("Mic is silent",
                    "The microphone only sent silence. Check that PrivoVoice is allowed in "
                    + "System Settings → Privacy & Security → Microphone, and that the "
                    + "input device isn't muted.")
        }
        return nil
    }

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
