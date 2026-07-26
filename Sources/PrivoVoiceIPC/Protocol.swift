// The wire protocol between the UI process and the engine sidecar.
//
// Messages are framed as: [opcode: UInt8][length: UInt32 big-endian][payload].
// Control messages carry an empty payload; text messages carry UTF-8; audio
// carries raw host-endian Float32 samples (both processes are same-arch, so no
// byte-swap). Foundation-only so both processes can share it cheaply.

import Foundation

/// UI → engine.
public enum EngineRequest: Sendable, Equatable {
    /// Liveness handshake.
    case ping
    /// Start a new utterance. `backend` is a `ModelBackend.rawValue`.
    case begin(modelPath: String, backend: String, locale: String, sampleRate: Double, channels: Int)
    /// A chunk of mono Float32 audio at the `begin` sample rate.
    case audio([Float])
    /// Stop capture and finalize; the engine replies `.final`.
    case end
    /// Abort the current utterance without finalizing.
    case cancel
    /// Shut the process down.
    case quit
    /// Clean up a final transcript with the formatter model installed at
    /// `modelPath`; the engine replies `.formatted` (or `.error`). The three
    /// bools mirror `FormatterOptions` (this module stays Foundation-only, so
    /// the struct is flattened onto the wire).
    case format(text: String, modelPath: String,
                removesFillers: Bool, formatsLists: Bool, appliesCorrections: Bool)
    /// Proactively load the formatter model installed at `modelPath` (and JIT
    /// its kernels) so the first `.format` doesn't pay the cold model load.
    /// Carries the same three `FormatterOptions` bools as `.format` so the
    /// prompt-prefix cache is anchored for the user's actual toggles (a warm-up
    /// with different options would re-anchor on the first real format).
    /// Best-effort: the engine replies `.warmed` when the attempt finishes
    /// (success or not); the app sends this fire-and-forget and ignores the ack.
    case warmFormatter(modelPath: String,
                       removesFillers: Bool, formatsLists: Bool, appliesCorrections: Bool)
    /// Drop the resident formatter model (frees ~1 GB when formatting turns
    /// off or the model is removed). No response — fire-and-forget, and a
    /// no-op when nothing is resident.
    case unloadFormatter
}

/// Engine → UI.
public enum EngineResponse: Sendable, Equatable {
    case pong
    /// The utterance session was accepted and the model is loading/started.
    case ready
    /// A revisable partial transcript.
    case partial(String)
    /// The committed transcript for the utterance.
    case final(String)
    /// A user-facing error string.
    case error(String)
    /// The cleaned-up transcript for a `.format` request.
    case formatted(String)
    /// Ack for `.warmFormatter`: the warm-up attempt finished (best-effort —
    /// sent whether or not the load succeeded; a failed load simply means the
    /// first `.format` pays the cold cost as before).
    case warmed
}

// MARK: - Opcodes

enum Opcode {
    // Requests
    static let ping: UInt8 = 0x01
    static let begin: UInt8 = 0x02
    static let audio: UInt8 = 0x03
    static let end: UInt8 = 0x04
    static let cancel: UInt8 = 0x05
    static let quit: UInt8 = 0x06
    static let format: UInt8 = 0x07
    static let warmFormatter: UInt8 = 0x08
    static let unloadFormatter: UInt8 = 0x09
    // Responses
    static let pong: UInt8 = 0x81
    static let ready: UInt8 = 0x82
    static let partial: UInt8 = 0x83
    static let final: UInt8 = 0x84
    static let error: UInt8 = 0x85
    static let formatted: UInt8 = 0x86
    static let warmed: UInt8 = 0x87
}

// MARK: - Encoding

/// JSON shape for `.begin`.
private struct BeginPayload: Codable {
    let modelPath: String
    let backend: String
    let locale: String
    let sampleRate: Double
    let channels: Int
}

/// JSON shape for `.warmFormatter` — mirrors `FormatPayload` minus the text.
private struct WarmFormatterPayload: Codable {
    let modelPath: String
    let removesFillers: Bool
    let formatsLists: Bool
    let appliesCorrections: Bool
}

/// JSON shape for `.format`.
private struct FormatPayload: Codable {
    let text: String
    let modelPath: String
    let removesFillers: Bool
    let formatsLists: Bool
    let appliesCorrections: Bool
}

public extension EngineRequest {
    /// Serialize to a framed message.
    func encoded() -> Data {
        switch self {
        case .ping:   return Frame.make(Opcode.ping, Data())
        case .end:    return Frame.make(Opcode.end, Data())
        case .cancel: return Frame.make(Opcode.cancel, Data())
        case .quit:   return Frame.make(Opcode.quit, Data())
        case let .begin(modelPath, backend, locale, sampleRate, channels):
            let payload = try! JSONEncoder().encode(
                BeginPayload(modelPath: modelPath, backend: backend, locale: locale,
                             sampleRate: sampleRate, channels: channels))
            return Frame.make(Opcode.begin, payload)
        case let .audio(samples):
            return Frame.make(Opcode.audio, samples.withUnsafeBytes { Data($0) })
        case let .format(text, modelPath, removesFillers, formatsLists, appliesCorrections):
            let payload = try! JSONEncoder().encode(
                FormatPayload(text: text, modelPath: modelPath,
                              removesFillers: removesFillers, formatsLists: formatsLists,
                              appliesCorrections: appliesCorrections))
            return Frame.make(Opcode.format, payload)
        case let .warmFormatter(modelPath, removesFillers, formatsLists, appliesCorrections):
            let payload = try! JSONEncoder().encode(
                WarmFormatterPayload(modelPath: modelPath,
                                     removesFillers: removesFillers, formatsLists: formatsLists,
                                     appliesCorrections: appliesCorrections))
            return Frame.make(Opcode.warmFormatter, payload)
        case .unloadFormatter:
            return Frame.make(Opcode.unloadFormatter, Data())
        }
    }

    /// Reconstruct from a decoded frame, or `nil` if malformed/unknown.
    static func decode(_ frame: Frame) -> EngineRequest? {
        switch frame.opcode {
        case Opcode.ping:   return .ping
        case Opcode.end:    return .end
        case Opcode.cancel: return .cancel
        case Opcode.quit:   return .quit
        case Opcode.begin:
            guard let p = try? JSONDecoder().decode(BeginPayload.self, from: frame.payload) else { return nil }
            return .begin(modelPath: p.modelPath, backend: p.backend, locale: p.locale,
                          sampleRate: p.sampleRate, channels: p.channels)
        case Opcode.audio:
            return .audio(frame.payload.toFloatArray())
        case Opcode.format:
            guard let p = try? JSONDecoder().decode(FormatPayload.self, from: frame.payload) else { return nil }
            return .format(text: p.text, modelPath: p.modelPath,
                           removesFillers: p.removesFillers, formatsLists: p.formatsLists,
                           appliesCorrections: p.appliesCorrections)
        case Opcode.warmFormatter:
            guard let p = try? JSONDecoder().decode(WarmFormatterPayload.self, from: frame.payload)
            else { return nil }
            return .warmFormatter(modelPath: p.modelPath,
                                  removesFillers: p.removesFillers, formatsLists: p.formatsLists,
                                  appliesCorrections: p.appliesCorrections)
        case Opcode.unloadFormatter:
            return .unloadFormatter
        default:
            return nil
        }
    }
}

public extension EngineResponse {
    func encoded() -> Data {
        switch self {
        case .pong:  return Frame.make(Opcode.pong, Data())
        case .ready: return Frame.make(Opcode.ready, Data())
        case let .partial(t): return Frame.make(Opcode.partial, Data(t.utf8))
        case let .final(t):   return Frame.make(Opcode.final, Data(t.utf8))
        case let .error(t):   return Frame.make(Opcode.error, Data(t.utf8))
        case let .formatted(t): return Frame.make(Opcode.formatted, Data(t.utf8))
        case .warmed: return Frame.make(Opcode.warmed, Data())
        }
    }

    static func decode(_ frame: Frame) -> EngineResponse? {
        switch frame.opcode {
        case Opcode.pong:  return .pong
        case Opcode.ready: return .ready
        case Opcode.partial: return .partial(String(decoding: frame.payload, as: UTF8.self))
        case Opcode.final:   return .final(String(decoding: frame.payload, as: UTF8.self))
        case Opcode.error:   return .error(String(decoding: frame.payload, as: UTF8.self))
        case Opcode.formatted: return .formatted(String(decoding: frame.payload, as: UTF8.self))
        case Opcode.warmed: return .warmed
        default: return nil
        }
    }
}

extension Data {
    /// Interpret the bytes as host-endian Float32.
    func toFloatArray() -> [Float] {
        guard !isEmpty else { return [] }
        let count = self.count / MemoryLayout<Float>.stride
        return withUnsafeBytes { raw in
            Array(UnsafeBufferPointer(start: raw.bindMemory(to: Float.self).baseAddress, count: count))
        }
    }
}
