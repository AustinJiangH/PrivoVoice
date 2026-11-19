// Reusable microphone capture → `AnalyzerInput` stream, with a peak meter.
//
// Mirrors the tap discipline in VoixfulTUI's mic session but returns a plain
// `AsyncStream<AnalyzerInput>` and exposes a thread-safe peak level (polled by
// the caller) instead of driving a terminal UI — so both the macOS app and a
// future iOS app can feed the analyzer the same way.

import AVFoundation
import Foundation
import os
import VoixfulSpeech

/// The microphone-capture surface `DictationController` depends on — abstracted
/// so tests can inject a synthetic capture (no real audio hardware).
public protocol AudioCapturing: Sendable {
    /// The hardware input format, or `nil` if no mic is configured.
    func inputFormat() -> AVAudioFormat?
    /// The audio input stream (call before `start()`).
    func makeStream() -> AsyncStream<AnalyzerInput>
    /// Begin capturing. Throws if no mic is configured / the engine won't start.
    func start() throws
    /// Stop capturing and finish the stream.
    func stop()
}

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

public final class AudioCapture: AudioCapturing, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let meter = PeakMeter()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var tapInstalled = false
    /// The format announced to the caller by `inputFormat()` — the engine is
    /// begun at its sample rate, so audio is resampled to it if the device's
    /// format later differs (a Bluetooth headset switching to its call
    /// profile, a device swapped mid-utterance).
    private var announcedFormat: AVAudioFormat?
    private var configObserver: NSObjectProtocol?
    /// Total buffers seen — lets the caller detect a dead/muted mic.
    public private(set) var receivedAnyAudio = false

    private static let log = Logger(subsystem: "com.privovoice.app", category: "audio")

    public init() {}

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    /// The microphone's hardware input format, or `nil` if none is configured.
    /// Readable before `start()` so the caller can announce the sample rate to
    /// the engine.
    public func inputFormat() -> AVAudioFormat? {
        let f = engine.inputNode.inputFormat(forBus: 0)
        guard f.channelCount > 0, f.sampleRate > 0 else { return nil }
        announcedFormat = f
        return f
    }

    /// Create the input stream. Call before `start()` so the analyzer can be
    /// wired up first and no audio is dropped during model cold-start.
    public func makeStream() -> AsyncStream<AnalyzerInput> {
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = cont
        return stream
    }

    /// Install the tap and start the engine. Throws if no mic is configured
    /// or microphone access is denied.
    public func start() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)
        #endif

        // Denied access doesn't fail the engine — macOS just delivers silence,
        // which looks like a dictation that heard nothing. Say so instead.
        // (`.notDetermined` is fine: starting the engine prompts.)
        let access = AVCaptureDevice.authorizationStatus(for: .audio)
        Self.log.notice("""
            starting mic: device \(AVCaptureDevice.default(for: .audio)?.localizedName ?? "none", privacy: .public), \
            access \(access.rawValue, privacy: .public)
            """)
        if access == .denied || access == .restricted {
            continuation?.finish()
            throw CaptureError.accessDenied
        }

        do {
            try installTap()
        } catch {
            continuation?.finish()
            throw error
        }

        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
            continuation?.finish()
            throw CaptureError.engineStart(error.localizedDescription)
        }
        receivedAnyAudio = false

        // A device or format change stops the engine without telling us — the
        // stream would just go quiet for the rest of the utterance. Re-tap and
        // restart on the new configuration instead.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    /// Stop the engine, remove the tap, and finish the stream.
    public func stop() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
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

    /// Tap the input node in its CURRENT hardware format, resampling to the
    /// announced rate when the two differ.
    private func installTap() throws {
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw CaptureError.noMicrophone
        }
        let target = announcedFormat ?? format
        if announcedFormat == nil { announcedFormat = format }
        let converter = Self.resampler(from: format, toRate: target.sampleRate)
        if converter != nil {
            Self.log.notice("""
                mic format \(format.sampleRate, privacy: .public) Hz differs from \
                \(target.sampleRate, privacy: .public) Hz; resampling
                """)
        }

        let meter = self.meter
        let cont = self.continuation
        // NOTE: macOS 27 deprecated this overload for an error-reporting variant,
        // but that variant currently imports into Swift only as a broken
        // `__installTap` (wrong `error:` type) with no proper refinement — so we
        // keep the working overload. Switch once the SDK ships the Swift wrapper.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            meter.record(Self.peakAmplitude(buffer))
            let out = converter.map { Self.resample(buffer, with: $0) } ?? Self.copy(buffer)
            guard let out else { return }
            cont?.yield(AnalyzerInput(buffer: out))
        }
        tapInstalled = true
    }

    /// The engine stopped itself for a configuration change (main queue).
    private func restartAfterConfigurationChange() {
        guard tapInstalled else { return }   // already stopped by us
        Self.log.notice("""
            audio configuration changed mid-recording (device \
            \(AVCaptureDevice.default(for: .audio)?.localizedName ?? "none", privacy: .public)); restarting
            """)
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
        do {
            try installTap()
            try engine.start()
        } catch {
            // The rest of the utterance is lost; the controller reports a
            // silent session if nothing usable came through.
            Self.log.error("mic restart failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Helpers

    public enum CaptureError: Error, CustomStringConvertible {
        case noMicrophone
        case accessDenied
        case engineStart(String)
        public var description: String {
            switch self {
            case .noMicrophone: return "No microphone is configured."
            case .accessDenied:
                return "PrivoVoice doesn't have microphone access. Allow it in "
                    + "System Settings → Privacy & Security → Microphone."
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

    /// A mono converter to `rate`, or `nil` when `format` is already at it
    /// (channel count is left to the caller's downmix).
    private static func resampler(from format: AVAudioFormat, toRate rate: Double) -> AVAudioConverter? {
        guard format.sampleRate != rate,
              let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return nil }
        return AVAudioConverter(from: format, to: mono)
    }

    private static func resample(_ src: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(src.frameLength) * ratio).rounded(.up)) + 32
        guard let dst = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity)
        else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: dst, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return src
        }
        guard status != .error, dst.frameLength > 0 else { return nil }
        return dst
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
