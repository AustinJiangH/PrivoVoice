// The PrivoVoice engine sidecar — the resident process that loads the Core AI model
// and transcribes, isolated from the UI. Reads framed `EngineRequest`s from
// stdin, drives an `InProcessDictationEngine`, and writes `EngineResponse`s to
// stdout. If it crashes or hangs, the UI process survives and respawns it.

import Foundation
import PrivoVoiceKit
import PrivoVoiceIPC
import VoixfulEngine

/// Thread-safe framed writer to a file handle (partials arrive off the engine's
/// reader task, concurrent with the request processor).
final class FrameWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    init(_ handle: FileHandle) { self.handle = handle }
    func send(_ response: EngineResponse) {
        let data = response.encoded()
        lock.lock(); defer { lock.unlock() }
        try? handle.write(contentsOf: data)
    }
}

@main
struct EngineHelper {
    static func main() async {
        // A dead parent pipe would otherwise SIGPIPE us mid-write; ignore it and
        // rely on EOF/`.quit` to exit.
        signal(SIGPIPE, SIG_IGN)

        let out = FrameWriter(.standardOutput)
        let engine = InProcessDictationEngine()

        // Blocking stdin reads on a dedicated thread → an async request stream.
        let (requests, continuation) = AsyncStream<EngineRequest>.makeStream(bufferingPolicy: .unbounded)
        let reader = Thread {
            let stdin = FileHandle.standardInput
            while let frame = FrameReader.read(from: stdin) {
                if let request = EngineRequest.decode(frame) {
                    continuation.yield(request)
                }
            }
            continuation.finish()   // parent closed the pipe
        }
        reader.stackSize = 1 << 20
        reader.start()

        // Process requests strictly in order.
        for await request in requests {
            switch request {
            case .ping:
                out.send(.pong)

            case let .begin(modelPath, backend, locale, sampleRate, channels):
                guard let resolved = ModelBackend(rawValue: backend) else {
                    out.send(.error("unknown backend '\(backend)'"))
                    continue
                }
                do {
                    try await engine.begin(
                        modelURL: URL(fileURLWithPath: modelPath),
                        backend: resolved,
                        locale: Locale(identifier: locale),
                        format: AudioStreamFormat(sampleRate: sampleRate, channels: channels),
                        onPartial: { text in out.send(.partial(text)) })
                    out.send(.ready)
                } catch {
                    out.send(.error("\(error)"))
                }

            case let .audio(samples):
                await engine.feed(samples)

            case .end:
                do {
                    let text = try await engine.end()
                    out.send(.final(text))
                } catch {
                    out.send(.error("\(error)"))
                }

            case .cancel:
                await engine.cancel()

            case let .format(text, modelPath, removesFillers, formatsLists, appliesCorrections):
                // The engine keeps the formatter LLM resident across requests,
                // so only the first format pays the model load. Serial loop:
                // a slow format blocks later requests — acceptable for v1.
                do {
                    let cleaned = try await engine.format(
                        text: text, modelPath: modelPath,
                        options: FormatterOptions(
                            removesFillers: removesFillers,
                            formatsLists: formatsLists,
                            appliesCorrections: appliesCorrections))
                    out.send(.formatted(cleaned))
                } catch {
                    out.send(.error("\(error)"))
                }

            case .quit:
                exit(0)
            }
        }

        // stdin hit EOF — the UI process is gone.
        exit(0)
    }
}
