// Coverage for the two-process wire protocol: pure framing round-trips, plus a
// real cross-process handshake that spawns the actual sidecar binary (no model
// needed — exercises spawn + IPC + clean shutdown).

import XCTest
import Foundation
import PrivoVoiceIPC

final class IPCFramingTests: XCTestCase {
    /// Round-trip every request kind through encode → FrameReader → decode.
    func testRequestRoundTrip() throws {
        let requests: [EngineRequest] = [
            .ping,
            .begin(modelPath: "/models/x.aimodel", backend: "nemotron", locale: "en-US",
                   sampleRate: 48000, channels: 1),
            .audio([0.0, 0.25, -0.5, 0.75, -1.0]),
            .audio([]),
            .end,
            .cancel,
            .quit,
            .format(text: "so first eggs then milk", modelPath: "/formatters/cleanup",
                    removesFillers: true, formatsLists: true, appliesCorrections: true),
            .format(text: "um keep the um fillers", modelPath: "/formatters/cleanup",
                    removesFillers: false, formatsLists: true, appliesCorrections: false),
            .format(text: "", modelPath: "",
                    removesFillers: false, formatsLists: false, appliesCorrections: false),
        ]
        let decoded = roundTrip(requests.map { $0.encoded() }).map { EngineRequest.decode($0) }
        XCTAssertEqual(decoded, requests.map { Optional($0) })
    }

    func testResponseRoundTrip() throws {
        let responses: [EngineResponse] = [
            .pong, .ready, .partial("hello wor"), .partial(""), .final("Hello, world."),
            .error("could not load model"),
            .formatted("First: eggs. Then: milk."), .formatted(""),
        ]
        let decoded = roundTrip(responses.map { $0.encoded() }).map { EngineResponse.decode($0) }
        XCTAssertEqual(decoded, responses.map { Optional($0) })
    }

    func testAudioSamplesSurviveExactly() throws {
        let samples: [Float] = (0..<1024).map { Float($0) * 0.001 - 0.5 }
        let frames = roundTrip([EngineRequest.audio(samples).encoded()])
        guard case let .audio(back)? = frames.first.flatMap(EngineRequest.decode) else {
            return XCTFail("did not decode audio")
        }
        XCTAssertEqual(back, samples)
    }

    /// Write frames into a pipe and read them back with the production reader.
    private func roundTrip(_ encoded: [Data]) -> [Frame] {
        let pipe = Pipe()
        for data in encoded { try? pipe.fileHandleForWriting.write(contentsOf: data) }
        try? pipe.fileHandleForWriting.close()
        var frames: [Frame] = []
        while let frame = FrameReader.read(from: pipe.fileHandleForReading) { frames.append(frame) }
        return frames
    }
}

final class SidecarProcessTests: XCTestCase {
    /// Spawn the real sidecar, ping it, expect a pong, then quit it cleanly.
    func testHandshakeAndCleanShutdown() throws {
        let helper = try locateHelper()
        let proc = Process()
        proc.executableURL = helper
        let stdin = Pipe()
        let stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        try proc.run()

        try? stdin.fileHandleForWriting.write(contentsOf: EngineRequest.ping.encoded())

        let response = readOneFrame(from: stdout.fileHandleForReading, timeout: 20)
        XCTAssertEqual(response.flatMap(EngineResponse.decode), .pong)

        try? stdin.fileHandleForWriting.write(contentsOf: EngineRequest.quit.encoded())
        let exited = waitForExit(proc, timeout: 10)
        XCTAssertTrue(exited, "sidecar did not exit on .quit")
        if exited { XCTAssertEqual(proc.terminationStatus, 0) }
        if proc.isRunning { proc.terminate() }
    }

    // MARK: helpers

    private func locateHelper() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["PRIVOVOICE_HELPER_PATH"] {
            return URL(fileURLWithPath: override)
        }
        // The .xctest bundle sits alongside the built executables.
        let dir = Bundle(for: SidecarProcessTests.self).bundleURL.deletingLastPathComponent()
        let helper = dir.appendingPathComponent("PrivoVoiceHelper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw XCTSkip("PrivoVoiceHelper not found at \(helper.path)")
        }
        return helper
    }

    /// Read one frame with a wall-clock timeout so a broken sidecar can't hang CI.
    private func readOneFrame(from handle: FileHandle, timeout: TimeInterval) -> Frame? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = FrameBox()
        DispatchQueue.global().async {
            box.frame = FrameReader.read(from: handle)
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + timeout) == .success ? box.frame : nil
    }

    private func waitForExit(_ proc: Process, timeout: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { proc.waitUntilExit(); semaphore.signal() }
        return semaphore.wait(timeout: .now() + timeout) == .success
    }

    private final class FrameBox: @unchecked Sendable { var frame: Frame? }
}
