// Additional coverage for logic the pre-merge review touched: the settings
// invalid-shortcut migration, full-field persistence, IPC frame/opcode edges,
// the downloader's synchronous failure + atomic local import, and the model
// store's validity/sizing rules.

import XCTest
import Foundation
import PrivoVoiceIPC
import VoixfulEngine
@testable import PrivoVoiceKit

private func tempURL(_ suffix: String = "") -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "voix-\(UUID().uuidString)\(suffix)")
}

// MARK: - Settings

final class SettingsMigrationTests: XCTestCase {
    @MainActor
    func testInvalidShortcutMigratedToDefaultOnLoad() {
        let store = tempURL("/settings.json")
        // Persist an invalid (bare-key) shortcut, as an older build might have.
        let a = AppSettings(storeURL: store)
        a.hotkey = KeyCombo(keyCode: 49, keyLabel: "Space", modifiers: [])
        a.saveNow()
        XCTAssertFalse(a.hotkey.isValidGlobalShortcut)

        // Loading it should heal to the default and rewrite the file.
        let b = AppSettings(storeURL: store)
        XCTAssertEqual(b.hotkey, .defaultCombo)
        let c = AppSettings(storeURL: store)
        XCTAssertEqual(c.hotkey, .defaultCombo, "the migration should have persisted")
    }

    @MainActor
    func testAllFieldsPersist() {
        let store = tempURL("/settings.json")
        let dir = tempURL("/models")
        let a = AppSettings(storeURL: store)
        a.modelsDirectory = dir
        a.selectedModelID = "granite-speech-4.1-2b-nar"
        a.autoCopy = false
        a.localeIdentifier = "de-DE"
        a.huggingFaceToken = "hf_secret"
        a.hotkey = KeyCombo(keyCode: 96, keyLabel: "F5", modifiers: [.control])
        a.saveNow()

        let b = AppSettings(storeURL: store)
        XCTAssertEqual(b.modelsDirectory, dir)
        XCTAssertEqual(b.selectedModelID, "granite-speech-4.1-2b-nar")
        XCTAssertFalse(b.autoCopy)
        XCTAssertEqual(b.localeIdentifier, "de-DE")
        XCTAssertEqual(b.huggingFaceToken, "hf_secret")
        XCTAssertEqual(b.hotkey, KeyCombo(keyCode: 96, keyLabel: "F5", modifiers: [.control]))
    }
}

// MARK: - IPC edges

final class FrameEdgeTests: XCTestCase {
    private func read(_ bytes: [UInt8]) -> Frame? {
        let pipe = Pipe()
        try? pipe.fileHandleForWriting.write(contentsOf: Data(bytes))
        try? pipe.fileHandleForWriting.close()
        return FrameReader.read(from: pipe.fileHandleForReading)
    }
    private func header(opcode: UInt8, length: UInt32) -> [UInt8] {
        var out = [opcode]
        withUnsafeBytes(of: length.bigEndian) { out.append(contentsOf: $0) }
        return out
    }

    func testOversizeLengthRejected() {
        // length > maxPayload must return nil, not try to allocate it.
        XCTAssertNil(read(header(opcode: 0x03, length: 0xFFFF_FFFF)))
    }
    func testTruncatedPayloadReturnsNil() {
        XCTAssertNil(read(header(opcode: 0x03, length: 100) + [1, 2, 3]))
    }
    func testShortHeaderReturnsNil() {
        XCTAssertNil(read([0x01, 0x02]))   // only 2 of 5 header bytes
    }
    func testZeroLengthFrameOK() {
        let frame = read(header(opcode: 0x04, length: 0))
        XCTAssertEqual(frame?.opcode, 0x04)
        XCTAssertEqual(frame?.payload.count, 0)
    }

    func testDecodeUnknownOpcodeReturnsNil() {
        XCTAssertNil(EngineRequest.decode(Frame(opcode: 0x7F, payload: Data())))
        XCTAssertNil(EngineResponse.decode(Frame(opcode: 0x7F, payload: Data())))
    }
    func testDecodeBeginWithBadJSONReturnsNil() {
        XCTAssertNil(EngineRequest.decode(Frame(opcode: 0x02, payload: Data("nope".utf8))))
    }
    func testDecodeEmptyTextMessages() {
        // .partial / .final with empty payload → empty strings.
        XCTAssertEqual(EngineResponse.decode(Frame(opcode: 0x83, payload: Data())), .partial(""))
        XCTAssertEqual(EngineResponse.decode(Frame(opcode: 0x84, payload: Data())), .final(""))
    }
}

// MARK: - Downloader

final class ModelDownloaderTests: XCTestCase {
    private func fakeSpec(id: String, download: DownloadSource?) -> ModelSpec {
        ModelSpec(
            id: id, displayName: "Fake", backend: .parakeet, upstreamRepo: "x/y",
            assetName: "\(id)-palette4.aimodel", parameters: "0.6 B", approxSizeMB: 10,
            languages: [LanguageTag("en")], streaming: false, speed: .good, accuracy: .good,
            weightsLicense: "MIT", werLeaderboard: nil, maxAudioSeconds: nil, summary: "",
            download: download)
    }

    @MainActor
    func testDownloadWithNoSourceFailsSynchronously() {
        let settings = AppSettings(storeURL: tempURL("/s.json"))
        settings.modelsDirectory = tempURL("/models")
        let store = ModelStore(settings: settings)
        let downloader = ModelDownloader(store: store, settings: settings)
        let spec = fakeSpec(id: "no-source", download: nil)

        downloader.download(spec)
        guard case .failed = downloader.state(for: spec) else {
            return XCTFail("expected .failed, got \(downloader.state(for: spec))")
        }
        XCTAssertFalse(downloader.isBusy(spec))
    }

    @MainActor
    func testImportLocalIsAtomicAndLeavesNoStaging() async {
        let settings = AppSettings(storeURL: tempURL("/s.json"))
        let models = tempURL("/models")
        settings.modelsDirectory = models
        let store = ModelStore(settings: settings)
        let downloader = ModelDownloader(store: store, settings: settings)
        let spec = fakeSpec(id: "importable", download: nil)

        // Fabricate a source .aimodel dir with a marker file.
        let source = tempURL("/src.aimodel")
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try? Data("weights".utf8).write(to: source.appending(path: "main.bin"))

        downloader.importLocal(spec, from: source)
        await waitUntil { if case .installed = downloader.state(for: spec) { return true }; return false }

        let dest = store.installURL(for: spec)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: dest.appending(path: "main.bin").path))
        let staging = models.appending(path: spec.assetName + ".partial")
        XCTAssertFalse(fm.fileExists(atPath: staging.path), "staging dir must be cleaned up")
    }

    @MainActor
    private func waitUntil(_ cond: @escaping @MainActor () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { XCTFail("timed out"); return }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
    }
}

// MARK: - ModelStore validity/sizing

final class ModelStoreValidityTests: XCTestCase {
    @MainActor
    func testEmptyDirectoryIsNotInstalled() throws {
        let models = tempURL("/models")
        let settings = AppSettings(storeURL: tempURL("/s.json"))
        settings.modelsDirectory = models
        let store = ModelStore(settings: settings)
        let spec = ModelCatalog.all[0]

        // An empty .aimodel dir must NOT count as installed.
        let asset = store.installURL(for: spec)
        try FileManager.default.createDirectory(at: asset, withIntermediateDirectories: true)
        store.refresh()
        XCTAssertFalse(store.isInstalled(spec))

        // Add a file → now installed, with a non-zero size.
        try Data("x".utf8).write(to: asset.appending(path: "main.bin"))
        store.refresh()
        XCTAssertTrue(store.isInstalled(spec))
        XCTAssertNotNil(store.formattedSize(for: spec))
    }
}
