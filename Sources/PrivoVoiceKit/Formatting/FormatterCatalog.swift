// The single formatter model we know how to install — Qwen3-1.7B as MLX 4-bit
// weights (config.json + tokenizer files + one ~968 MB safetensors shard),
// published on Hugging Face by mlx-community. A general instruct model driven
// by a tight few-shot prompt (see TranscriptFormatter); it replaced the
// getonit/transcription-cleanup-llama3.2-1b fine-tune, which only handled raw
// lowercase input and returned Parakeet-style punctuated transcripts verbatim.
//
// License: Apache-2.0 (both the Qwen3 base weights and the mlx-community
// conversion), which resolves the unlicensed-model concern the previous
// fine-tune carried. The download is user-initiated and the weights are never
// redistributed by us.

import Foundation

/// Constants describing the transcript-formatter model. One model for now; if
/// this ever grows into a real catalog, mirror `ModelCatalog`'s spec shape.
public enum FormatterCatalog {
    /// Hugging Face repo containing the MLX 4-bit weights themselves
    /// (`library_name: mlx`, 4-bit quantization — no conversion needed).
    public static let repoID = "mlx-community/Qwen3-1.7B-4bit"
    /// Pinned revision. The repo has no tagged releases, so track `main`.
    public static let revision = "main"
    /// Directory name under the Formatters root the snapshot is installed as.
    public static let installSlug = "qwen3-1.7b-4bit"
    /// Human-readable name for settings/onboarding surfaces.
    public static let displayName = "Transcript Polish (Qwen3 1.7B, 4-bit)"
    /// Rough on-disk size (weights ~968 MB + tokenizer ~11 MB), for UI copy.
    public static let approxSizeDescription = "~1 GB"
    /// Hub glob patterns covering everything the runtime needs: weights +
    /// index, config, tokenizer files, and any chat template. Must stay a
    /// superset of what `FormatterStore.looksInstalled` requires (config.json,
    /// tokenizer.json, a *.safetensors shard).
    public static let filePatterns = ["*.safetensors", "*.json", "*.jinja"]
}
