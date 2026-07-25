// The shipping model catalog — UI-agnostic metadata for every checkpoint PrivoVoice
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
    /// Longest audio (seconds) the model transcribes well in a single pass before
    /// it must be segmented. `nil` ⇒ effectively unbounded (a native streaming
    /// model). Drives the HUD's countdown "lens" and the segment reminders.
    public let maxAudioSeconds: Double?
    /// One-line "what it's best for".
    public let summary: String
    /// Where to auto-download from; `nil` ⇒ install by importing a local asset.
    public let download: DownloadSource?

    public init(
        id: String, displayName: String, backend: ModelBackend, upstreamRepo: String,
        assetName: String, parameters: String, approxSizeMB: Int, languages: [LanguageTag],
        streaming: Bool, speed: Rating, accuracy: Rating, weightsLicense: String,
        werLeaderboard: Double?, maxAudioSeconds: Double?, summary: String,
        download: DownloadSource?
    ) {
        self.id = id; self.displayName = displayName; self.backend = backend
        self.upstreamRepo = upstreamRepo; self.assetName = assetName
        self.parameters = parameters; self.approxSizeMB = approxSizeMB
        self.languages = languages; self.streaming = streaming; self.speed = speed
        self.accuracy = accuracy; self.weightsLicense = weightsLicense
        self.werLeaderboard = werLeaderboard; self.maxAudioSeconds = maxAudioSeconds
        self.summary = summary; self.download = download
    }

    /// Longest audio this model transcribes in ONE pass (16 kHz seconds), sourced
    /// from the core `ModelBackend`. Beyond it the transcriber segments on silence
    /// automatically (Voixful `LongForm`), so this is an informational hint — e.g.
    /// a HUD countdown to the next re-transcribe boundary — NOT a dictation cap.
    /// `nil` for streaming backends (Nemotron), which have no window.
    public var singlePassWindowSeconds: Double? { backend.singlePassWindowSeconds }
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
            approxSizeMB: 330,   // measured Palette4 .aimodel on disk
            languages: [LanguageTag("en")],
            streaming: true,
            speed: .excellent,
            accuracy: .good,
            weightsLicense: "NVIDIA Open Model License",
            werLeaderboard: 5.73,
            maxAudioSeconds: nil,   // streaming: unbounded (caches across the utterance)
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
            approxSizeMB: 335,   // measured Palette4 .aimodel on disk
            languages: [LanguageTag("en")],
            streaming: false,
            speed: .excellent,
            accuracy: .good,
            weightsLicense: "CC-BY-4.0",
            werLeaderboard: 5.39,
            maxAudioSeconds: 1440,   // 24 min single pass, full attention (HF model card)
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
            approxSizeMB: 370,   // measured Palette4 .aimodel on disk
            languages: parakeetV3Languages,
            streaming: false,
            speed: .excellent,
            accuracy: .good,
            weightsLicense: "CC-BY-4.0",
            werLeaderboard: 5.66,
            maxAudioSeconds: 1440,   // 24 min default (HF card); ~3 h possible with local attention
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
            approxSizeMB: 1100,   // measured Palette4 .aimodel on disk
            languages: ["en", "fr", "de", "es", "pt"].map(LanguageTag.init),
            streaming: false,
            speed: .good,
            accuracy: .excellent,
            weightsLicense: "Apache-2.0",
            werLeaderboard: 4.95,
            maxAudioSeconds: 30,   // conservative: no official max; caller should chunk long audio
            summary: "Best accuracy we ship; strong live + file balance. No decode loop.",
            download: .huggingFace(repo: "\(hfOrg)/voixful-granite-speech-4.1-2b-nar", revision: "main")
        ),
        // Cohere Transcribe is intentionally NOT listed: the upstream checkpoint
        // is access-gated by CohereLabs, so we don't redistribute it. The engine
        // backend still exists in the core for locally-imported assets.
        ModelSpec(
            id: "canary-qwen-2.5b",
            displayName: "Canary-Qwen",
            backend: .canary,
            upstreamRepo: "nvidia/canary-qwen-2.5b",
            assetName: "canary-qwen-2.5b-palette4.aimodel",
            parameters: "2.5 B",
            approxSizeMB: 2400,   // measured Palette4 .aimodel on disk
            languages: [LanguageTag("en")],
            streaming: false,
            speed: .fair,
            accuracy: .excellent,
            weightsLicense: "CC-BY-4.0",
            werLeaderboard: 5.06,
            maxAudioSeconds: 40,   // trained max 40 s; segment beyond that (HF model card)
            summary: "Best punctuation + casing. Prefer for files over live dictation.",
            download: .huggingFace(repo: "\(hfOrg)/voixful-canary-qwen-2.5b", revision: "main")
        ),
        // Whisper — the four middle-to-best checkpoints by WER. English-only here:
        // the engine's WhisperEngine.supportedLocales is en-US, and non-English is
        // unbenchmarked. All ship a hard 30 s single-pass window (segment beyond it).
        ModelSpec(
            id: "whisper-small",
            displayName: "Whisper Small",
            backend: .whisper,
            upstreamRepo: "openai/whisper-small",
            assetName: "whisper-small-palette4.aimodel",
            parameters: "0.24 B",
            approxSizeMB: 634,
            languages: [LanguageTag("en")],
            streaming: false,
            speed: .good,
            accuracy: .fair,
            weightsLicense: "MIT",
            werLeaderboard: 9.8,
            maxAudioSeconds: 30,   // Whisper's hard 30 s single-pass window
            summary: "Compact Whisper; solid English accuracy at a modest footprint.",
            download: .huggingFace(repo: "\(hfOrg)/voixful-whisper-small", revision: "main")
        ),
        ModelSpec(
            id: "whisper-medium",
            displayName: "Whisper Medium",
            backend: .whisper,
            upstreamRepo: "openai/whisper-medium",
            assetName: "whisper-medium-palette4.aimodel",
            parameters: "0.77 B",
            approxSizeMB: 1897,
            languages: [LanguageTag("en")],
            streaming: false,
            speed: .good,
            accuracy: .fair,
            weightsLicense: "MIT",
            werLeaderboard: 8.6,
            maxAudioSeconds: 30,   // Whisper's hard 30 s single-pass window
            summary: "Larger Whisper; better English accuracy than Small.",
            download: .huggingFace(repo: "\(hfOrg)/voixful-whisper-medium", revision: "main")
        ),
        ModelSpec(
            id: "whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            backend: .whisper,
            upstreamRepo: "openai/whisper-large-v3-turbo",
            assetName: "whisper-large-v3-turbo-palette4.aimodel",
            parameters: "0.81 B",
            approxSizeMB: 970,
            languages: [LanguageTag("en")],
            streaming: false,
            speed: .good,
            accuracy: .fair,
            weightsLicense: "MIT",
            werLeaderboard: 7.83,
            maxAudioSeconds: 30,   // Whisper's hard 30 s single-pass window
            summary: "Near-large accuracy with a lighter, faster decoder.",
            download: .huggingFace(repo: "\(hfOrg)/voixful-whisper-large-v3-turbo", revision: "main")
        ),
        ModelSpec(
            id: "whisper-large-v3",
            displayName: "Whisper Large v3",
            backend: .whisper,
            upstreamRepo: "openai/whisper-large-v3",
            assetName: "whisper-large-v3-palette4.aimodel",
            parameters: "1.55 B",
            approxSizeMB: 3773,
            languages: [LanguageTag("en")],
            streaming: false,
            speed: .fair,
            accuracy: .fair,
            weightsLicense: "MIT",
            werLeaderboard: 7.44,
            maxAudioSeconds: 30,   // Whisper's hard 30 s single-pass window
            summary: "Best Whisper English accuracy; heaviest of the four.",
            download: .huggingFace(repo: "\(hfOrg)/voixful-whisper-large-v3", revision: "main")
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
