// The macOS `DictationEngine` that runs transcription in the sidecar process.
//
// Spawns `PrivoVoiceHelper` lazily, keeps it resident across utterances, and
// forwards begin/audio/end over the stdio protocol. If the sidecar dies, the
// reader hits EOF, any in-flight `end()` fails cleanly, and the next `begin()`
// respawns it — the UI process is never taken down by an engine crash.

import Foundation
import PrivoVoiceKit
import PrivoVoiceIPC
import VoixfulEngine

public actor HelperProcessDictationEngine: DictationEngine {
    private let helperURL: URL

    private var process: Process?
    private var stdin: FileHandle?
    private var consumeTask: Task<Void, Never>?
    private var onPartial: (@Sendable (String) -> Void)?
    private var pendingBegin: CheckedContinuation<Void, Error>?
    private var pendingEnd: CheckedContinuation<String, Error>?
    private var pendingFormat: CheckedContinuation<String, Error>?
    private var beginTimeout: Task<Void, Never>?
    private var endTimeout: Task<Void, Never>?
    private var formatTimeout: Task<Void, Never>?

    /// A begin that hasn't acknowledged (`.ready`/`.error`) in this long is
    /// treated as a hung sidecar. `.begin` only builds the transcriber (the model
    /// loads later), so this is generous.
    private let beginTimeoutSeconds: UInt64 = 20
    /// A finalize that doesn't return in this long is treated as a hang.
    private let endTimeoutSeconds: UInt64 = 60
    /// A transcript format that doesn't return in this long is treated as a
    /// hang. Longer than the caller's own fallback window (60 s) so the session
    /// falls back to the raw transcript before the sidecar gets recycled.
    private let formatTimeoutSeconds: UInt64 = 75

    public init(helperURL: URL) {
        self.helperURL = helperURL
    }

    // MARK: DictationEngine

    public func begin(
        modelURL: URL, backend: ModelBackend, locale: Locale,
        format: AudioStreamFormat, onPartial: @escaping @Sendable (String) -> Void
    ) async throws {
        try ensureRunning()
        self.onPartial = onPartial
        // Await the sidecar's ack so a bad model/backend surfaces as a thrown
        // error here (not a silent empty transcript later).
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pendingBegin = c
            send(.begin(
                modelPath: modelURL.path, backend: backend.rawValue, locale: locale.identifier,
                sampleRate: format.sampleRate, channels: format.channels))
            let seconds = beginTimeoutSeconds
            beginTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                await self?.timedOut(begin: true)
            }
        }
    }

    public func feed(_ samples: [Float]) {
        send(.audio(samples))
    }

    public func end() async throws -> String {
        guard process != nil else { return "" }
        return try await withCheckedThrowingContinuation { continuation in
            pendingEnd = continuation
            send(.end)
            let seconds = endTimeoutSeconds
            endTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                await self?.timedOut(begin: false)
            }
        }
    }

    public func cancel() {
        send(.cancel)
        resumeBegin(.failure(HelperError.cancelled))
        resumeEnd(.success(""))
        resumeFormat(.failure(HelperError.cancelled))
    }

    /// Format the final transcript in the sidecar (the formatter LLM stays
    /// resident there). Any failure is thrown; the session layer falls back to
    /// the raw transcript.
    public func format(
        text: String, modelPath: String, options: FormatterOptions
    ) async throws -> String {
        try ensureRunning()
        return try await withCheckedThrowingContinuation { continuation in
            pendingFormat = continuation
            send(.format(text: text, modelPath: modelPath,
                         removesFillers: options.removesFillers,
                         formatsLists: options.formatsLists,
                         appliesCorrections: options.appliesCorrections))
            let seconds = formatTimeoutSeconds
            formatTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                await self?.formatTimedOut()
            }
        }
    }

    /// A pending format didn't respond in time — fail it and kill the sidecar
    /// (the serial request loop is wedged behind the hung generate). A late
    /// `.formatted` after this is dropped by `handle(_:)`.
    private func formatTimedOut() {
        guard pendingFormat != nil else { return }
        resumeFormat(.failure(HelperError.timeout))
        killProcess()
    }

    /// A pending begin/end didn't get a response in time — fail it and kill the
    /// sidecar so the next `begin()` respawns a clean one.
    private func timedOut(begin: Bool) {
        let stillPending = begin ? (pendingBegin != nil) : (pendingEnd != nil)
        guard stillPending else { return }
        if begin { resumeBegin(.failure(HelperError.timeout)) }
        else { resumeEnd(.failure(HelperError.timeout)) }
        killProcess()
    }

    // MARK: Process lifecycle

    private func ensureRunning() throws {
        if let process, process.isRunning { return }

        let proc = Process()
        proc.executableURL = helperURL
        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        // stderr inherits the parent's for debug visibility.
        try proc.run()

        self.process = proc
        self.stdin = inPipe.fileHandleForWriting

        // Decode the sidecar's stdout on a dedicated thread, funnel through an
        // ordered stream so partials always precede the final they belong to.
        let (responses, continuation) = AsyncStream<EngineResponse>.makeStream(bufferingPolicy: .unbounded)
        let reader = ResponseReader(
            handle: outPipe.fileHandleForReading,
            onFrame: { continuation.yield($0) },
            onEOF: { continuation.finish() })
        reader.start()

        consumeTask = Task { [weak self] in
            for await response in responses { await self?.handle(response) }
            await self?.handleTermination()
        }
    }

    private func handle(_ response: EngineResponse) {
        switch response {
        case .pong:
            break
        case .ready:
            resumeBegin(.success(()))
        case let .partial(text):
            onPartial?(text)
        case let .final(text):
            resumeEnd(.success(text))
        case let .formatted(text):
            // No pending format (timeout/cancel already resumed it) ⇒ a late
            // response from a recycled request — drop it.
            resumeFormat(.success(text))
        case let .error(message):
            // A begin-time failure (bad model) routes to the pending begin; a
            // finalize failure to the pending end; a format failure to the
            // pending format. At most one is in flight (the sidecar loop is
            // serial), so route to whichever is pending.
            if pendingBegin != nil {
                resumeBegin(.failure(HelperError.engine(message)))
            } else if pendingEnd != nil {
                resumeEnd(.failure(HelperError.engine(message)))
            } else {
                resumeFormat(.failure(HelperError.engine(message)))
            }
        }
    }

    /// The sidecar exited (crash or clean). Fail any in-flight begin/end and clear
    /// state so the next `begin()` respawns it.
    private func handleTermination() {
        resumeBegin(.failure(HelperError.crashed))
        resumeEnd(.failure(HelperError.crashed))
        resumeFormat(.failure(HelperError.crashed))
        process = nil
        stdin = nil
        onPartial = nil
        consumeTask = nil
    }

    private func killProcess() {
        process?.terminate()
        process = nil
        stdin = nil
    }

    private func send(_ request: EngineRequest) {
        guard let stdin else { return }
        try? stdin.write(contentsOf: request.encoded())
    }

    private func resumeBegin(_ result: Result<Void, Error>) {
        beginTimeout?.cancel(); beginTimeout = nil
        guard let continuation = pendingBegin else { return }
        pendingBegin = nil
        continuation.resume(with: result)
    }

    private func resumeEnd(_ result: Result<String, Error>) {
        endTimeout?.cancel(); endTimeout = nil
        guard let continuation = pendingEnd else { return }
        pendingEnd = nil
        continuation.resume(with: result)
    }

    private func resumeFormat(_ result: Result<String, Error>) {
        formatTimeout?.cancel(); formatTimeout = nil
        guard let continuation = pendingFormat else { return }
        pendingFormat = nil
        continuation.resume(with: result)
    }

    enum HelperError: Error, CustomStringConvertible {
        case crashed
        case timeout
        case cancelled
        case engine(String)
        var description: String {
            switch self {
            case .crashed: return "The transcription engine process stopped unexpectedly."
            case .timeout: return "The transcription engine stopped responding."
            case .cancelled: return "Cancelled."
            case .engine(let m): return m
            }
        }
    }
}

/// Owns the blocking read loop off the actor. `@unchecked Sendable` so the
/// non-Sendable `FileHandle` can be read on its own thread; only this object
/// touches it.
private final class ResponseReader: @unchecked Sendable {
    private let handle: FileHandle
    private let onFrame: @Sendable (EngineResponse) -> Void
    private let onEOF: @Sendable () -> Void

    init(handle: FileHandle,
         onFrame: @escaping @Sendable (EngineResponse) -> Void,
         onEOF: @escaping @Sendable () -> Void) {
        self.handle = handle
        self.onFrame = onFrame
        self.onEOF = onEOF
    }

    func start() {
        let thread = Thread { [self] in
            while let frame = FrameReader.read(from: handle) {
                if let response = EngineResponse.decode(frame) { onFrame(response) }
            }
            onEOF()
        }
        thread.stackSize = 1 << 20
        thread.start()
    }
}
