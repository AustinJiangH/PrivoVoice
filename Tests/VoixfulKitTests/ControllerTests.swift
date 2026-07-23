// State-machine tests for DictationController, driven by a mock capture + mock
// engine (no real mic, no model). These guard the bugs the pre-merge review
// found: session overlap on re-press, and dropped tail audio on release.

import XCTest
import Foundation
import AVFoundation
import VoixfulSpeech
import VoixfulEngine
@testable import VoixfulKit

// MARK: - Mocks

/// A synthetic capture with an eager unbounded stream, so a test can `yield`
/// buffers at any time (they buffer until the controller's forwarder drains).
final class MockCapture: AudioCapturing, @unchecked Sendable {
    let format: AVAudioFormat?
    private let stream: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private(set) var didStart = false
    private(set) var didStop = false

    init(format: AVAudioFormat? = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)) {
        self.format = format
        (self.stream, self.continuation) =
            AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
    }
    func inputFormat() -> AVAudioFormat? { format }
    func makeStream() -> AsyncStream<AnalyzerInput> { stream }
    func start() throws { didStart = true }
    func stop() { didStop = true; continuation.finish() }
    func yield(frames: Int, value: Float = 0.5) {
        continuation.yield(AnalyzerInput(buffer: Self.buffer(frames: frames, value: value)))
    }
    static func buffer(frames: Int, value: Float) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        let ch = buf.floatChannelData![0]
        for i in 0..<frames { ch[i] = value }
        return buf
    }
}

/// Records begin/feed/end/cancel calls for assertions.
actor MockEngine: DictationEngine {
    private(set) var beginCount = 0
    private(set) var fedBatches = 0
    private(set) var fedSamples = 0
    private(set) var endCount = 0
    private(set) var cancelCount = 0
    var finalText = "Hello."
    var throwOnBegin: Error?
    private var onPartial: (@Sendable (String) -> Void)?

    func begin(modelURL: URL, backend: ModelBackend, locale: Locale,
               format: AudioStreamFormat, onPartial: @escaping @Sendable (String) -> Void) async throws {
        beginCount += 1
        self.onPartial = onPartial
        if let throwOnBegin { throw throwOnBegin }
    }
    func feed(_ samples: [Float]) { fedBatches += 1; fedSamples += samples.count }
    func end() async throws -> String { endCount += 1; return finalText }
    func cancel() { cancelCount += 1 }
    func emitPartial(_ t: String) { onPartial?(t) }
    struct Boom: Error {}
}

/// Hands out fresh MockCaptures and remembers them.
final class CaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [MockCapture] = []
    var all: [MockCapture] { lock.lock(); defer { lock.unlock() }; return made }
    func factory() -> @Sendable () -> any AudioCapturing {
        { let c = MockCapture(); self.lock.lock(); self.made.append(c); self.lock.unlock(); return c }
    }
}

// MARK: - Tests

final class DictationControllerTests: XCTestCase {

    @MainActor
    private func makeController(
        engine: MockEngine, makeCapture: @escaping @Sendable () -> any AudioCapturing,
        installed: Bool = true
    ) throws -> (DictationController, AppState) {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "voixctl-\(UUID().uuidString)")
        let settings = AppSettings(storeURL: tmp.appending(path: "settings.json"))
        settings.modelsDirectory = tmp.appending(path: "models")
        let store = ModelStore(settings: settings)
        if installed {
            let spec = ModelCatalog.all[0]
            let asset = store.installURL(for: spec)
            try FileManager.default.createDirectory(at: asset, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: asset.appending(path: "marker"))
            settings.selectedModelID = spec.id
            store.refresh()
        }
        let appState = AppState()
        let controller = DictationController(
            appState: appState, settings: settings, store: store,
            engine: engine, makeCapture: makeCapture)
        return (controller, appState)
    }

    /// Poll an async condition on the main actor until true or timeout.
    @MainActor
    private func waitUntil(_ condition: @escaping () async -> Bool,
                           timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            if Date() > deadline { XCTFail("timed out waiting for condition", file: file, line: line); return }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
    }

    // T1.6 — model gating (no mic needed; returns before capture).
    @MainActor
    func testStartRequiresInstalledModel() throws {
        let engine = MockEngine()
        let (controller, appState) = try makeController(
            engine: engine, makeCapture: { MockCapture() }, installed: false)
        XCTAssertFalse(controller.canStart)
        controller.start()
        XCTAssertFalse(controller.isRunning)
        XCTAssertNotNil(appState.lastError)
    }

    // T1.1 — re-press while active does NOT start a second session.
    @MainActor
    func testSecondStartWhileActiveIsIgnored() async throws {
        let engine = MockEngine()
        let box = CaptureBox()
        let (controller, _) = try makeController(engine: engine, makeCapture: box.factory())
        controller.start()
        XCTAssertTrue(controller.isRunning)
        await waitUntil { await engine.beginCount == 1 }
        controller.start()   // guarded by `active != nil`
        // Give any erroneous second begin a chance, then assert still one.
        try? await Task.sleep(nanoseconds: 30_000_000)
        let begins = await engine.beginCount
        XCTAssertEqual(begins, 1)
        XCTAssertEqual(box.all.count, 1, "no second capture should be created")
    }

    // T1.2 — every buffered sample is forwarded before end() (no tail drop).
    @MainActor
    func testTailAudioIsNotDropped() async throws {
        let engine = MockEngine()
        let box = CaptureBox()
        let (controller, appState) = try makeController(engine: engine, makeCapture: box.factory())
        controller.start()
        // Wait until the mic has "opened" (matches reality: no audio before start).
        await waitUntil { box.all.first?.didStart == true }
        let capture = box.all[0]
        capture.yield(frames: 100)
        capture.yield(frames: 100)
        capture.yield(frames: 100)
        controller.stop()   // finishes the stream; the 3 buffered buffers still drain
        await waitUntil { appState.phase == .idle }
        let batches = await engine.fedBatches
        let ends = await engine.endCount
        XCTAssertEqual(batches, 3, "all buffered audio must reach feed() before end()")
        XCTAssertEqual(ends, 1)
    }

    // T1.3 — final transcript is trimmed + delivered; empty preserves prior.
    @MainActor
    func testFinalTranscriptDeliveredAndTrimmed() async throws {
        let engine = MockEngine()
        await engine.setFinal("  Hello, world.  ")
        let box = CaptureBox()
        let (controller, appState) = try makeController(engine: engine, makeCapture: box.factory())
        var delivered: String?
        controller.onFinalTranscript = { delivered = $0 }
        controller.start()
        controller.stop()
        await waitUntil { appState.phase == .idle }
        XCTAssertEqual(delivered, "Hello, world.")
        XCTAssertEqual(appState.lastTranscript, "Hello, world.")
    }

    @MainActor
    func testEmptyTranscriptPreservesPrevious() async throws {
        let engine = MockEngine()
        await engine.setFinal("   ")   // whitespace only
        let box = CaptureBox()
        let (controller, appState) = try makeController(engine: engine, makeCapture: box.factory())
        var deliveredCount = 0
        controller.onFinalTranscript = { _ in deliveredCount += 1 }
        controller.start()
        controller.stop()
        await waitUntil { appState.phase == .idle }
        XCTAssertEqual(deliveredCount, 0, "no-speech tap must not deliver")
        XCTAssertEqual(appState.lastTranscript, "")
    }

    // T1.1b — re-press during the finalize window is ignored (no overlap on the
    // resident engine).
    @MainActor
    func testStartDuringFinalizeIsIgnored() async throws {
        let engine = MockEngine()
        let box = CaptureBox()
        let (controller, appState) = try makeController(engine: engine, makeCapture: box.factory())
        controller.start()
        await waitUntil { await engine.beginCount == 1 }
        controller.stop()                 // sets finalizing = true synchronously
        controller.start()                // must be ignored while finalizing
        let begins = await engine.beginCount
        XCTAssertEqual(begins, 1)
        await waitUntil { appState.phase == .idle }
    }

    // T1.4 — cancel uses cancel() (not end()) and re-allows start.
    @MainActor
    func testCancelDoesNotFinalize() async throws {
        let engine = MockEngine()
        let box = CaptureBox()
        let (controller, _) = try makeController(engine: engine, makeCapture: box.factory())
        controller.start()
        await waitUntil { await engine.beginCount == 1 }
        controller.cancel()
        await waitUntil { await engine.cancelCount == 1 }
        let ends = await engine.endCount
        XCTAssertEqual(ends, 0, "cancel must not finalize")
        XCTAssertFalse(controller.isRunning)
    }

    // T1.5 — mono downmix + peak (pure, no controller lifecycle).
    func testMonoSamplesDownmixAndPeak() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4)!
        buf.frameLength = 4
        let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
        // frame 0: (0.2, 0.4)->0.3 ; frame 1: (-0.6,-0.6)->-0.6 ; 2: (1,1)->1 ; 3: (0,0)->0
        l[0] = 0.2; r[0] = 0.4
        l[1] = -0.6; r[1] = -0.6
        l[2] = 1.0; r[2] = 1.0
        l[3] = 0.0; r[3] = 0.0
        let (samples, peak) = DictationController.monoSamples(buf)
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[0], 0.3, accuracy: 1e-6)
        XCTAssertEqual(samples[1], -0.6, accuracy: 1e-6)
        XCTAssertEqual(peak, 1.0, accuracy: 1e-6)   // max |avg|, clamped to 1
    }

    func testMonoSamplesEmptyBuffer() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1)!
        buf.frameLength = 0
        let (samples, peak) = DictationController.monoSamples(buf)
        XCTAssertTrue(samples.isEmpty)
        XCTAssertEqual(peak, 0)
    }
}

extension MockEngine {
    func setFinal(_ t: String) { finalText = t }
}
