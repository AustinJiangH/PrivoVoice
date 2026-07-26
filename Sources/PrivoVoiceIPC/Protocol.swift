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
    // Responses
    static let pong: UInt8 = 0x81
    static let ready: UInt8 = 0x82
    static let partial: UInt8 = 0x83
    static let final: UInt8 = 0x84
    static let error: UInt8 = 0x85
    static let formatted: UInt8 = 0x86
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
