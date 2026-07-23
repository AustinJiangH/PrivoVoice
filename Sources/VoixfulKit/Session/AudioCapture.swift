// Reusable microphone capture → `AnalyzerInput` stream, with a peak meter.
//
// Mirrors the tap discipline in VoixfulTUI's mic session but returns a plain
// `AsyncStream<AnalyzerInput>` and exposes a thread-safe peak level (polled by
// the caller) instead of driving a terminal UI — so both the macOS app and a
// future iOS app can feed the analyzer the same way.

import AVFoundation
import Foundation
import VoixfulSpeech

/// Thread-safe peak accumulator. The audio tap writes it on a real-time thread;
/// the UI samples-and-resets it on the main actor.
final class PeakMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0

    func record(_ value: Float) {
        lock.lock(); peak = max(peak, value); lock.unlock()
    }
    func takePeak() -> Float {
        lock.lock(); let p = peak; peak = 0; lock.unlock(); return p
    }
}

public final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let meter = PeakMeter()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var tapInstalled = false
    /// Total buffers seen — lets the caller detect a dead/muted mic.
    public private(set) var receivedAnyAudio = false

    public init() {}

    /// Create the input stream. Call before `start()` so the analyzer can be
    /// wired up first and no audio is dropped during model cold-start.
    public func makeStream() -> AsyncStream<AnalyzerInput> {
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = cont
        return stream
    }

    /// Install the tap and start the engine. Throws if no mic is configured.
    public func start() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)
        #endif

        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            continuation?.finish()
            throw CaptureError.noMicrophone
        }

        let meter = self.meter
        let cont = self.continuation
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            meter.record(Self.peakAmplitude(buffer))
            guard let copy = Self.copy(buffer) else { return }
            cont?.yield(AnalyzerInput(buffer: copy))
        }
        tapInstalled = true

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            continuation?.finish()
            throw CaptureError.engineStart(error.localizedDescription)
        }
        receivedAnyAudio = false
    }

    /// Stop the engine, remove the tap, and finish the stream.
    public func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        continuation?.finish()
        continuation = nil
    }

    /// Current peak (0…1) since the last call, then reset. Poll this ~20×/s.
    public func sampleLevel() -> Float {
        let p = meter.takePeak()
        if p > 0 { receivedAnyAudio = true }
        return min(1, p)
    }

    // MARK: Helpers

    public enum CaptureError: Error, CustomStringConvertible {
        case noMicrophone
        case engineStart(String)
        public var description: String {
            switch self {
            case .noMicrophone: return "No microphone is configured."
            case .engineStart(let m): return "Could not start audio engine: \(m)"
            }
        }
    }

    private static func peakAmplitude(_ buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0, let channels = buffer.floatChannelData else { return 0 }
        var peak: Float = 0
        for c in 0..<Int(buffer.format.channelCount) {
            let p = channels[c]
            for i in 0..<n { peak = max(peak, abs(p[i])) }
        }
        return peak
    }

    private static func copy(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let dst = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: src.frameLength),
              let s = src.floatChannelData, let d = dst.floatChannelData else { return nil }
        dst.frameLength = src.frameLength
        for ch in 0..<Int(src.format.channelCount) {
            d[ch].update(from: s[ch], count: Int(src.frameLength))
        }
        return dst
    }
}
