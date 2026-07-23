// Length-prefixed framing over a byte stream (a pipe between the two processes).

import Foundation

/// One decoded frame: an opcode plus its raw payload.
public struct Frame: Sendable, Equatable {
    public let opcode: UInt8
    public let payload: Data
    public init(opcode: UInt8, payload: Data) {
        self.opcode = opcode
        self.payload = payload
    }

    /// Encode `opcode` + `payload` as `[opcode][UInt32 BE length][payload]`.
    public static func make(_ opcode: UInt8, _ payload: Data) -> Data {
        var out = Data(capacity: 5 + payload.count)
        out.append(opcode)
        var len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}

/// Blocking frame reader over a `FileHandle` (used on a dedicated read thread in
/// each process). Returns `nil` on clean EOF or a short/garbled stream.
public enum FrameReader {
    public static func read(from handle: FileHandle) -> Frame? {
        guard let header = readExactly(5, from: handle) else { return nil }
        let opcode = header[header.startIndex]
        let length = header.subdata(in: header.startIndex.advanced(by: 1)..<header.startIndex.advanced(by: 5))
            .withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        if length == 0 { return Frame(opcode: opcode, payload: Data()) }
        guard let payload = readExactly(Int(length), from: handle) else { return nil }
        return Frame(opcode: opcode, payload: payload)
    }

    /// Read exactly `count` bytes, looping across short reads. `nil` on EOF.
    private static func readExactly(_ count: Int, from handle: FileHandle) -> Data? {
        var buffer = Data()
        buffer.reserveCapacity(count)
        while buffer.count < count {
            let chunk = handle.readData(ofLength: count - buffer.count)
            if chunk.isEmpty { return nil }   // EOF before the full frame
            buffer.append(chunk)
        }
        return buffer
    }
}
