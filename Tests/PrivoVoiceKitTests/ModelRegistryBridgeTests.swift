// Drift guard: the hand-authored `ModelCatalog` is the source of truth for what
// PrivoVoice ships, but the engine's `models.json` registry describes the same
// checkpoints. This test cross-checks every catalog row that also appears in the
// registry, so a hand-authored value can never silently diverge from models.json.

import XCTest
import Foundation
import VoixfulEngine
@testable import PrivoVoiceKit

final class ModelRegistryBridgeTests: XCTestCase {
    /// The catalog's download repo string for a spec, if it downloads from HF.
    private func downloadRepo(_ spec: ModelSpec) -> String? {
        switch spec.download {
        case .huggingFace(let repo, _): return repo
        case .none: return nil
        }
    }

    func testCatalogRowsMatchRegistryWhereBothExist() {
        var checked = 0
        for spec in ModelCatalog.all {
            // Tolerate catalog ids absent from the registry (app-only rows).
            guard let entry = ModelCatalog.registryEntry(id: spec.id) else { continue }
            checked += 1

            // Asset directory name.
            XCTAssertEqual(spec.assetName, entry.download.assetName,
                           "\(spec.id): assetName drifted from models.json")

            // Download repo (resolved `org/name` strings must match).
            XCTAssertEqual(downloadRepo(spec), entry.download.repo,
                           "\(spec.id): download repo drifted from models.json")

            // Backend.
            XCTAssertEqual(entry.modelBackend, spec.backend,
                           "\(spec.id): backend drifted from models.json")

            // Leaderboard WER.
            XCTAssertEqual(spec.werLeaderboard, entry.wer,
                           "\(spec.id): werLeaderboard drifted from models.json")

            // Single-pass window must match the registry's value for this id.
            XCTAssertEqual(spec.singlePassWindowSeconds, entry.singlePassWindowSeconds,
                           "\(spec.id): singlePassWindowSeconds drifted from models.json")
        }
        XCTAssertGreaterThan(checked, 0, "expected at least one catalog id present in the registry")
    }

    func testWhisperModelsArePresentInRegistry() {
        let whisperIDs = [
            "whisper-small", "whisper-medium",
            "whisper-large-v3-turbo", "whisper-large-v3",
        ]
        for id in whisperIDs {
            XCTAssertNotNil(ModelCatalog.registryEntry(id: id),
                            "\(id) must be present in the engine registry (models.json)")
        }
    }
}
