// Drift guard: the onboarding use-case profiles reference model ids as plain
// strings, so this test enforces that every recommended / alternate id resolves
// to a real `ModelCatalog` spec — no id can silently dangle when the catalog
// changes — and that the profile catalog itself is well-formed.

import XCTest
import Foundation
@testable import PrivoVoiceKit

final class UseCaseProfilesTests: XCTestCase {
    func testCatalogIsNonEmptyAndCountInRange() {
        XCTAssertFalse(UseCaseCatalog.all.isEmpty, "expected at least one use-case profile")
        XCTAssertTrue((4...6).contains(UseCaseCatalog.all.count),
                      "expected 4–6 profiles, got \(UseCaseCatalog.all.count)")
    }

    func testProfileIDsAreUnique() {
        let ids = UseCaseCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "profile ids must be unique: \(ids)")
    }

    func testEveryReferencedModelIDResolves() {
        for profile in UseCaseCatalog.all {
            XCTAssertNotNil(ModelCatalog.spec(id: profile.recommendedModelID),
                            "\(profile.id): recommendedModelID '\(profile.recommendedModelID)' does not resolve in ModelCatalog")
            for altID in profile.alsoGoodModelIDs {
                XCTAssertNotNil(ModelCatalog.spec(id: altID),
                                "\(profile.id): alsoGood id '\(altID)' does not resolve in ModelCatalog")
            }
        }
    }

    func testRecommendedModelIsNotAlsoListedAsAlternate() {
        for profile in UseCaseCatalog.all {
            XCTAssertFalse(profile.alsoGoodModelIDs.contains(profile.recommendedModelID),
                           "\(profile.id): recommended model duplicated in alsoGoodModelIDs")
        }
    }

    func testProfileLookupByID() {
        let first = UseCaseCatalog.all[0]
        XCTAssertEqual(UseCaseCatalog.profile(id: first.id)?.id, first.id)
        XCTAssertNil(UseCaseCatalog.profile(id: "no-such-use-case"))
    }

    func testRecommendedModelResolvesToCorrectSpec() {
        for profile in UseCaseCatalog.all {
            let spec = UseCaseCatalog.recommendedModel(for: profile.id)
            XCTAssertNotNil(spec, "\(profile.id): recommendedModel(for:) returned nil")
            XCTAssertEqual(spec?.id, profile.recommendedModelID,
                           "\(profile.id): recommendedModel(for:) returned the wrong spec")
            XCTAssertEqual(spec?.id, profile.recommendedModel?.id,
                           "\(profile.id): convenience property disagrees with the catalog resolver")
        }
        XCTAssertNil(UseCaseCatalog.recommendedModel(for: "no-such-use-case"))
    }

    /// fast-capture and everyday rank Parakeet v2 first (English) then v3 (25
    /// European languages): English resolves to v2, a v3-only language to v3.
    func testLanguageAwareRecommendationPicksParakeetV2orV3() {
        for id in ["fast-capture", "everyday"] {
            guard let profile = UseCaseCatalog.profile(id: id) else {
                XCTFail("missing profile \(id)"); continue
            }
            XCTAssertEqual(profile.recommendedModel(for: "en")?.id, "parakeet-tdt-0.6b-v2",
                           "\(id): English should resolve to Parakeet v2")
            // German is covered by v3 but not v2, so it must fall through to v3.
            XCTAssertEqual(profile.recommendedModel(for: "de")?.id, "parakeet-tdt-0.6b-v3",
                           "\(id): German should resolve to Parakeet v3")
        }
    }

    /// A language no candidate covers falls back to the plain recommended model.
    func testLanguageAwareRecommendationFallsBackToRecommended() {
        guard let profile = UseCaseCatalog.profile(id: "everyday") else {
            return XCTFail("missing everyday profile")
        }
        XCTAssertEqual(profile.recommendedModel(for: "zz")?.id, profile.recommendedModelID)
    }
}
