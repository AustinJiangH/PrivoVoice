// A `DictationEngine` that drives `VoixfulAnalyzer` in this process. This is the
// portable path (iOS, or a single-process macOS build) and is also what the
// engine sidecar runs inside itself.

import AVFoundation
import Foundation
import VoixfulSpeech
import VoixfulEngine

public actor InProcessDictationEngine: DictationEngine {
    private var analyzer: VoixfulAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var startTask: Task<Void, Error>?
    private var readerTask: Task<String?, Never>?
    private var format: AVAudioFormat?
    /// Resident transcript formatter (and the model directory it was built
    /// for), kept warm across utterances so only the first format cold-loads.
    private var formatter: TranscriptFormatter?
    private var formatterPath: String?

    public init() {}

    public func begin(
        modelURL: URL,
        backend: ModelBackend,
        locale: Locale,
        format streamFormat: AudioStreamFormat,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws {
        // Build the transcriber up front so a bad model fails before capture.
        let transcriber = try TranscriberFactory.makeLive(
            modelURL: modelURL, backend: backend, locale: locale)

        guard let fmt = AVAudioFormat(
            standardFormatWithSampleRate: streamFormat.sampleRate,
            channels: AVAudioChannelCount(max(1, streamFormat.channels))
        ) else {
            throw EngineError.badFormat
        }
        self.format = fmt

        let analyzer = VoixfulAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        self.analyzer = analyzer
        self.inputContinuation = continuation

        // Read results: partials via the callback, keep the last final.
        self.readerTask = Task {
            var lastFinal: String?
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal { lastFinal = text } else { onPartial(text) }
                }
            } catch {
                // Surfaced by end()/cancel() via the empty/failed transcript.
            }
            return lastFinal
        }

        // Cold-load the model + start pumping in the background; end() waits on it.
        self.startTask = Task { try await analyzer.start(inputSequence: stream) }
    }

    public func feed(_ samples: [Float]) {
        guard let inputContinuation, let format,
              let buffer = Self.makeBuffer(samples, format: format) else { return }
        inputContinuation.yield(AnalyzerInput(buffer: buffer))
    }

    public func end() async throws -> String {
        inputContinuation?.finish()
        do {
            try await startTask?.value
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            // prepare()/finalize threw and never closed the result stream — cancel
            // so the reader unblocks instead of hanging forever.
            await analyzer?.cancelAndFinishNow()
            cleanup()
            throw EngineError.transcription("\(error)")
        }
        let final = (await readerTask?.value ?? nil) ?? ""
        cleanup()
        return final.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func cancel() async {
        inputContinuation?.finish()
        await analyzer?.cancelAndFinishNow()
        readerTask?.cancel()
        cleanup()
    }

    /// Cancellation-responsive: cancelling the calling task (the session's
    /// polish timeout) stops the generation within a token and throws — see
    /// `TranscriptFormatter.format`.
    public func format(
        text: String, modelPath: String, options: FormatterOptions
    ) async throws -> String {
        try await resolvedFormatter(modelPath: modelPath).format(text, options: options)
    }

    /// Load the formatter model + warm its kernels and prompt cache (anchored
    /// for `options`, so the user's real toggles don't re-anchor on the first
    /// format). Returns when the warm-up attempt finishes (callers
    /// fire-and-forget it); failure is swallowed — the first real format then
    /// cold-loads as before.
    public func warmFormatter(modelPath: String, options: FormatterOptions) async {
        try? await resolvedFormatter(modelPath: modelPath).prewarm(options: options)
    }

    /// Drop the resident formatter (model container + prompt cache, ~1 GB).
    /// The formatter is asked to unload its own heavy state explicitly —
    /// merely dropping our reference leaves the weights resident until the
    /// actor's deferred deallocation, which can be arbitrarily late. The next
    /// format — if any — reloads as on first use (cheap within the same
    /// process: the kernels stay JIT-compiled and the weights page-cached).
    public func unloadFormatter() async {
        // Nil the reference BEFORE the await: actor reentrancy would otherwise
        // let a racing warm/format grab the outgoing instance mid-unload and
        // reload ~1 GB into a formatter nothing references — which could then
        // never be unloaded.
        let outgoing = formatter
        formatter = nil
        formatterPath = nil
        await outgoing?.unload()
    }

    /// The resident formatter for `modelPath` (rebuilt if the path changed).
    private func resolvedFormatter(modelPath: String) -> TranscriptFormatter {
        if formatter == nil || formatterPath != modelPath {
            // Unload a replaced instance explicitly (fire-and-forget) — same
            // reasoning as `unloadFormatter`: dropping the reference alone
            // leaves its weights resident indefinitely. The reference is
            // already swapped out by the time the task runs, so a concurrent
            // request can only see the new instance.
            if let outgoing = formatter {
                Task { await outgoing.unload() }
            }
            formatter = TranscriptFormatter(directory: URL(fileURLWithPath: modelPath))
            formatterPath = modelPath
        }
        return formatter!
    }

    private func cleanup() {
        analyzer = nil
        inputContinuation = nil
        startTask = nil
        readerTask = nil
        format = nil
    }

    /// Wrap mono Float32 samples in an `AVAudioPCMBuffer` at `format`.
    private static func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            channel[0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }

    enum EngineError: Error, CustomStringConvertible {
        case badFormat
        case transcription(String)
        var description: String {
            switch self {
            case .badFormat: return "Unsupported audio format."
            case .transcription(let m): return m
            }
        }
    }
}
