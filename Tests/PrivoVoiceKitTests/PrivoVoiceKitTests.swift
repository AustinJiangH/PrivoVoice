// Headless smoke coverage for the reusable core — no model asset, no GUI.
// Exercises catalog integrity, settings round-trip, key-combo encoding, and the
// model store's path logic.

import XCTest
import Foundation
import VoixfulEngine
@testable import PrivoVoiceKit

final class CatalogTests: XCTestCase {
    func testCatalogIsNonEmptyAndIDsAreUnique() {
        let all = ModelCatalog.all
        XCTAssertFalse(all.isEmpty)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "model ids must be unique")
    }

    func testAssetNamesAreUniqueAimodelDirectories() {
        for spec in ModelCatalog.all {
            XCTAssertTrue(spec.assetName.hasSuffix(".aimodel"), "\(spec.id) asset must be an .aimodel")
        }
        let names = ModelCatalog.all.map(\.assetName)
        XCTAssertEqual(Set(names).count, names.count, "asset names must be unique")
    }

    func testEverySpecHasAtLeastOneLanguage() {
        for spec in ModelCatalog.all {
            XCTAssertFalse(spec.languages.isEmpty, "\(spec.id) has no languages")
        }
    }

    func testLookupBySpecID() {
        let first = ModelCatalog.all[0]
        XCTAssertEqual(ModelCatalog.spec(id: first.id)?.id, first.id)
        XCTAssertNil(ModelCatalog.spec(id: "does-not-exist"))
    }

    func testAccuracyRatingIsMonotonicWithWER() {
        // A model with a better (lower) leaderboard WER must not carry a lower
        // accuracy pip than a worse one — the pips are defined as bucketed WER.
        let rated = ModelCatalog.all.compactMap { spec -> (wer: Double, rating: Rating)? in
            spec.werLeaderboard.map { (wer: $0, rating: spec.accuracy) }
        }
        for a in rated {
            for b in rated where b.wer < a.wer {
                XCTAssertGreaterThanOrEqual(
                    b.rating, a.rating,
                    "model with WER \(b.wer) should rate ≥ one with WER \(a.wer)")
            }
        }
    }

    func testOnlyNemotronStreams() {
        for spec in ModelCatalog.all {
            XCTAssertEqual(spec.streaming, spec.backend == .nemotron,
                           "\(spec.id): only the Nemotron backend streams natively")
        }
    }

    func testAllLanguagesAreSortedAndDeduped() {
        let langs = ModelCatalog.allLanguages
        XCTAssertEqual(Set(langs).count, langs.count)
        XCTAssertEqual(langs, langs.sorted { $0.displayName < $1.displayName })
    }
}

final class KeyComboTests: XCTestCase {
    func testDefaultComboIsFnHold() {
        // Default is hold-`fn` (modifier-only) — types nothing, and is a valid
        // global shortcut.
        XCTAssertTrue(KeyCombo.defaultCombo.isModifierOnly)
        XCTAssertTrue(KeyCombo.defaultCombo.modifiers.contains(.function))
        XCTAssertFalse(KeyCombo.defaultCombo.isEmpty)
        XCTAssertTrue(KeyCombo.defaultCombo.isValidGlobalShortcut)
    }

    func testEmptyCombo() {
        XCTAssertTrue(KeyCombo(keyCode: nil, modifiers: []).isEmpty)
    }

    func testValidGlobalShortcutRule() {
        // Valid: key+modifier, function key, fn alone, fn+key, multi-modifier.
        XCTAssertTrue(KeyCombo(keyCode: 49, keyLabel: "Space", modifiers: [.option]).isValidGlobalShortcut)
        XCTAssertTrue(KeyCombo(keyCode: 96, keyLabel: "F5", modifiers: []).isValidGlobalShortcut)
        XCTAssertTrue(KeyCombo(keyCode: nil, modifiers: [.function]).isValidGlobalShortcut)
        XCTAssertTrue(KeyCombo(keyCode: 49, keyLabel: "Space", modifiers: [.function]).isValidGlobalShortcut)
        XCTAssertTrue(KeyCombo(keyCode: nil, modifiers: [.control, .option]).isValidGlobalShortcut)
        // Invalid: bare printable key (tap would swallow it everywhere), and a
        // lone common modifier (fires on every press while typing).
        XCTAssertFalse(KeyCombo(keyCode: 49, keyLabel: "Space", modifiers: []).isValidGlobalShortcut)
        XCTAssertFalse(KeyCombo(keyCode: nil, modifiers: [.shift]).isValidGlobalShortcut)
        XCTAssertFalse(KeyCombo(keyCode: nil, modifiers: []).isValidGlobalShortcut)
    }

    func testCodableRoundTrip() throws {
        let combo = KeyCombo(keyCode: 96, keyLabel: "F5", modifiers: [.command, .option])
        let data = try JSONEncoder().encode(combo)
        let back = try JSONDecoder().decode(KeyCombo.self, from: data)
        XCTAssertEqual(combo, back)
        XCTAssertTrue(back.displayString.contains("F5"))
    }

    func testModifierDisplayOrder() {
        let mods: KeyModifiers = [.command, .control, .shift, .option]
        // ⌃⌥⇧⌘ canonical order
        XCTAssertEqual(mods.displayString, "⌃⌥⇧⌘")
    }
}

final class SettingsTests: XCTestCase {
    private func tempStore() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "voixful-test-\(UUID().uuidString)/settings.json")
    }

    @MainActor
    func testDefaultsWhenNoFile() {
        let s = AppSettings(storeURL: tempStore())
        XCTAssertTrue(s.autoCopy)
        XCTAssertNil(s.selectedModelID)
        XCTAssertEqual(s.localeIdentifier, "en-US")
        XCTAssertTrue(s.modelsDirectory.path.contains("Library/PrivoVoice/Models"))
    }

    @MainActor
    func testPersistenceRoundTrip() {
        let url = tempStore()
        let a = AppSettings(storeURL: url)
        a.selectedModelID = "granite-speech-4.1-2b-nar"
        a.autoCopy = false
        a.saveNow()

        let b = AppSettings(storeURL: url)
        XCTAssertEqual(b.selectedModelID, "granite-speech-4.1-2b-nar")
        XCTAssertFalse(b.autoCopy)
    }
}

final class ModelStoreTests: XCTestCase {
    @MainActor
    func testInstallURLUsesModelsDirectory() {
        let s = AppSettings(storeURL: FileManager.default.temporaryDirectory
            .appending(path: "voixful-test-\(UUID().uuidString)/settings.json"))
        let dir = FileManager.default.temporaryDirectory.appending(path: "voixful-models-\(UUID().uuidString)")
        s.modelsDirectory = dir
        let store = ModelStore(settings: s)
        let spec = ModelCatalog.all[0]
        XCTAssertEqual(store.installURL(for: spec), dir.appending(path: spec.assetName, directoryHint: .isDirectory))
        XCTAssertFalse(store.isInstalled(spec))
    }

    @MainActor
    func testDetectsInstalledDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "voixful-models-\(UUID().uuidString)")
        let s = AppSettings(storeURL: FileManager.default.temporaryDirectory
            .appending(path: "voixful-test-\(UUID().uuidString)/settings.json"))
        s.modelsDirectory = dir
        let store = ModelStore(settings: s)
        let spec = ModelCatalog.all[0]

        // Fabricate a non-empty .aimodel directory.
        let asset = dir.appending(path: spec.assetName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: asset, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: asset.appending(path: "marker"))
        store.refresh()
        XCTAssertTrue(store.isInstalled(spec))
        XCTAssertNotNil(store.formattedSize(for: spec))

        try store.delete(spec)
        XCTAssertFalse(store.isInstalled(spec))
    }
}
