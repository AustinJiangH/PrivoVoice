// A thin bridge from the hand-authored `ModelCatalog` to the engine's
// data-backed `ModelRegistry` (decoded from Voixful's bundled `models.json`).
//
// The catalog stays the single source of truth for what PrivoVoice *ships* and how
// it presents each model. This bridge only exposes the registry so a drift-guard
// test can cross-check the hand-authored rows against `models.json` — it does NOT
// derive the catalog from the registry.

import Foundation
import VoixfulEngine

extension ModelCatalog {
    /// The engine's bundled model registry (`Voixful/Resources/models.json`).
    public static let registry = ModelRegistry.bundled

    /// The registry entry for a catalog id, or `nil` if the registry doesn't list
    /// it (some shipped rows may be app-only, and vice versa).
    public static func registryEntry(id: String) -> ModelEntry? {
        registry.model(id: id)
    }
}
