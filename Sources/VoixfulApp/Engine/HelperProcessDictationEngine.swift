// The macOS `DictationEngine` that runs transcription in the sidecar process.
//
// Spawns `VoixfulEngineHelper` lazily, keeps it resident across utterances, and
// forwards begin/audio/end over the stdio protocol. If the sidecar dies, the
// reader hits EOF, any in-flight `end()` fails cleanly, and the next `begin()`
// respawns it — the UI process is never taken down by an engine crash.

import Foundation
import VoixfulKit
import VoixfulIPC
import VoixfulEngine

public actor HelperProcessDictationEngine: DictationEngine {
    private let helperURL: URL

    private var process: Process?
    private var stdin: FileHandle?
    private var consumeTask: Task<Void, Never>?
    private var onPartial: (@Sendable (String) -> Void)?
    private var pendingEnd: CheckedContinuation<String, Error>?

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
        send(.begin(
            modelPath: modelURL.path, backend: backend.rawValue, locale: locale.identifier,
            sampleRate: format.sampleRate, channels: format.channels))
    }

    public func feed(_ samples: [Float]) {
        send(.audio(samples))
    }

    public func end() async throws -> String {
        guard process != nil else { return "" }
        return try await withCheckedThrowingContinuation { continuation in
            pendingEnd = continuation
            send(.end)
        }
    }

    public func cancel() {
        send(.cancel)
        resumeEnd(.success(""))
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
        case .pong, .ready:
            break
        case let .partial(text):
            onPartial?(text)
        case let .final(text):
            resumeEnd(.success(text))
        case let .error(message):
            resumeEnd(.failure(HelperError.engine(message)))
        }
    }

    /// The sidecar exited (crash or clean). Fail any in-flight `end()` and clear
    /// state so the next `begin()` respawns it.
    private func handleTermination() {
        resumeEnd(.failure(HelperError.crashed))
        process = nil
        stdin = nil
        onPartial = nil
        consumeTask = nil
    }

    private func send(_ request: EngineRequest) {
        guard let stdin else { return }
        try? stdin.write(contentsOf: request.encoded())
    }

    private func resumeEnd(_ result: Result<String, Error>) {
        guard let continuation = pendingEnd else { return }
        pendingEnd = nil
        continuation.resume(with: result)
    }

    enum HelperError: Error, CustomStringConvertible {
        case crashed
        case engine(String)
        var description: String {
            switch self {
            case .crashed: return "The transcription engine process stopped unexpectedly."
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
