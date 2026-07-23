// The shipping model catalog — UI-agnostic metadata for every checkpoint Voixful
// supports, mirroring the support matrix in the repo README. This is display +
// install metadata only; the runtime backend is still auto-detected from the
// `.aimodel` when a transcriber is built.

import Foundation
import VoixfulEngine

/// A qualitative 1–3 rating rendered as filled/empty pips in the UI.
public enum Rating: Int, Sendable, Comparable, Codable {
    case fair = 1, good = 2, excellent = 3

    public static func < (lhs: Rating, rhs: Rating) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .fair: return "Fair"
        case .good: return "Good"
        case .excellent: return "Excellent"
        }
    }
}

/// A language a model can transcribe, keyed by ISO-639 code so the Models page
/// can filter on it. `displayName` is localized for the current user.
public struct LanguageTag: Sendable, Hashable, Codable, Identifiable {
    public let code: String            // e.g. "en", "de", "fr"
    public var id: String { code }
    public init(_ code: String) { self.code = code }

    public var displayName: String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }
}

/// Where an installable asset can be fetched from. The `.aimodel` is a directory;
/// a Hugging Face repo is expected to mirror that directory's contents at its root.
public enum DownloadSource: Sendable, Hashable, Codable {
    case huggingFace(repo: String, revision: String)
}

/// Static, UI-agnostic description of one installable model checkpoint.
public struct ModelSpec: Identifiable, Sendable, Hashable {
    /// Stable slug (also the install directory basename, sans `.aimodel`).
    public let id: String
    public let displayName: String
    public let backend: ModelBackend
    /// Upstream checkpoint the weights derive from (attribution).
    public let upstreamRepo: String
    /// The on-disk `.aimodel` directory name once installed.
    public let assetName: String
    public let parameters: String
    public let approxSizeMB: Int
    public let languages: [LanguageTag]
    /// Native streaming (words appear while you speak) vs. re-transcribe partials.
    public let streaming: Bool
    /// Live-mic responsiveness (how fast a refresh pass is).
    public let speed: Rating
    /// Transcription accuracy (inverse of leaderboard WER, bucketed).
    public let accuracy: Rating
    public let weightsLicense: String
    /// Open ASR Leaderboard mean WER for the source checkpoint (lower = better).
    public let werLeaderboard: Double?
    /// One-line "what it's best for".
    public let summary: String
    /// Where to auto-download from; `nil` ⇒ install by importing a local asset.
    public let download: DownloadSource?

    public init(
        id: String, displayName: String, backend: ModelBackend, upstreamRepo: String,
        assetName: String, parameters: String, approxSizeMB: Int, languages: [LanguageTag],
        streaming: Bool, speed: Rating, accuracy: Rating, weightsLicense: String,
        werLeaderboard: Double?, summary: String, download: DownloadSource?
    ) {
        self.id = id; self.displayName = displayName; self.backend = backend
        self.upstreamRepo = upstreamRepo; self.assetName = assetName
        self.parameters = parameters; self.approxSizeMB = approxSizeMB
        self.languages = languages; self.streaming = streaming; self.speed = speed
        self.accuracy = accuracy; self.weightsLicense = weightsLicense
        self.werLeaderboard = werLeaderboard; self.summary = summary; self.download = download
    }
}

/// The 25 European locales Parakeet v3 covers (README: "European incl. …").
private let parakeetV3Languages: [LanguageTag] = [
    "en", "de", "fr", "es", "it", "pt", "pl", "uk", "ru", "nl", "cs", "sv", "da",
    "fi", "el", "hu", "ro", "bg", "hr", "sk", "sl", "lt", "lv", "et", "mt",
].map(LanguageTag.init)

/// The catalog. Order = recommended default first (Nemotron: lowest-latency
/// dictation).
public enum ModelCatalog {
    /// Planned Hugging Face org the converted assets publish under. Until the
    /// assets are published, downloads surface a clear "not yet available"
    /// error and users install via Import.
    static let hfOrg = "AustinJiangH"

    public static let all: [ModelSpec] = [
        ModelSpec(
            id: "nemotron-speech-streaming-en-0.6b",
            displayName: "Nemotron Streaming",
            backend: .nemotron,
            upstreamRepo: "nvidia/nemotron-speech-streaming-en-0.6b",
            assetName: "nemotron-speech-streaming-en-0.6b-palette4.aimodel",
            parameters: "0.6 B",
            approxSizeMB: 620,
            languages: [LanguageTag("en")],
            streaming: true,
            speed: .excellent,
            accuracy: .good,
            weightsLicense: "NVIDIA Open Model License",
            werLeaderboard: 5.73,
            summary: "Lowest-latency dictation — words appear while you speak.",
            download: .huggingFace(repo: "\(hfOrg)/voixful-nemotron-speech-streaming-en-0.6b", revision: "main")
        ),
        ModelSpec(
            id: "parakeet-tdt-0.6b-v2",
            displayName: "Parakeet TDT v2",
            backend: .parakeet,
            upstreamRepo: "nvidia/parakeet-tdt-0.6b-v2",
            assetName: "parakeet-tdt-0.6b-v2-palette4.aimodel",
            parameters: "0.6 B",
            approxSizeMB: 620,
            languages: [LanguageTag("en")],
            streaming: false,
            speed: .excellent,
            accuracy: .excellent,
            weightsLicense: "CC-BY-4.0",
            werLeaderboard: 5.39,
            summary: "Smallest footprint, fastest passes, best English accuracy of the small tier.",
            download: .huggingFace(repo: "\(hfOrg)/voixful-parakeet-tdt-0.6b-v2", revision: "main")
        ),
        ModelSpec(
            id: "parakeet-tdt-0.6b-v3",
            displayName: "Parakeet TDT v3",
            backend: .parakeet,
            upstreamRepo: "nvidia/parakeet-tdt-0.6b-v3",
            assetName: "parakeet-tdt-0.6b-v3-palette4.aimodel",
            parameters: "0.6 B",
            approxSizeMB: 640,
            languages: parakeetV3Languages,
            streaming: false,
            speed: .excellent,
            accuracy: .good,
            weightsLicense: "CC-BY-4.0",
            werLeaderboard: 5.66,
            summary: "25 European languages, fast passes.",
            download: .huggingFace(repo: "\(hfOrg)/voixful-parakeet-tdt-0.6b-v3", revision: "main")
        ),
        ModelSpec(
            id: "granite-speech-4.1-2b-nar",
            displayName: "Granite Speech NAR",
            backend: .granite,
            upstreamRepo: "ibm-granite/granite-speech-4.1-2b-nar",
            assetName: "granite-speech-4.1-2b-nar-palette4.aimodel",
            parameters: "2.2 B",
            approxSizeMB: 2300,
            languages: ["en", "fr", "de", "es", "pt"].map(LanguageTag.init),
            streaming: false,
            speed: .good,
            accuracy: .excellent,
            weightsLicense: "Apache-2.0",
            werLeaderboard: 4.95,
            summary: "Best accuracy we ship; strong live + file balance. No decode loop.",
            download: .huggingFace(repo: "\(hfOrg)/voixful-granite-speech-4.1-2b-nar", revision: "main")
        ),
        ModelSpec(
            id: "cohere-transcribe-03-2026",
            displayName: "Cohere Transcribe",
            backend: .cohere,
            upstreamRepo: "CohereLabs/cohere-transcribe-03-2026",
            assetName: "cohere-transcribe-03-2026-palette4.aimodel",
            parameters: "2 B",
            approxSizeMB: 2100,
            languages: ["en", "de", "fr", "es", "it", "pt", "nl", "ja", "ko", "zh", "ar", "ru", "hi", "tr"].map(LanguageTag.init),
            streaming: false,
            speed: .good,
            accuracy: .good,
            weightsLicense: "upstream (gated)",
            werLeaderboard: 5.20,
            summary: "14 languages via an attention encoder-decoder.",
            download: .huggingFace(repo: "\(hfOrg)/voixful-cohere-transcribe-03-2026", revision: "main")
        ),
        ModelSpec(
            id: "canary-qwen-2.5b",
            displayName: "Canary-Qwen",
            backend: .canary,
            upstreamRepo: "nvidia/canary-qwen-2.5b",
            assetName: "canary-qwen-2.5b-palette4.aimodel",
            parameters: "2.5 B",
            approxSizeMB: 2600,
            languages: [LanguageTag("en")],
            streaming: false,
            speed: .fair,
            accuracy: .excellent,
            weightsLicense: "CC-BY-4.0",
            werLeaderboard: 5.06,
            summary: "Best punctuation + casing. Prefer for files over live dictation.",
            download: .huggingFace(repo: "\(hfOrg)/voixful-canary-qwen-2.5b", revision: "main")
        ),
    ]

    /// Look up a spec by its stable id.
    public static func spec(id: String) -> ModelSpec? { all.first { $0.id == id } }

    /// Every distinct language across the catalog, sorted by display name — the
    /// source for the Models page language filter.
    public static var allLanguages: [LanguageTag] {
        let unique = Set(all.flatMap { $0.languages })
        return unique.sorted { $0.displayName < $1.displayName }
    }
}
