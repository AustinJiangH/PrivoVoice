// Use-case profiles — the onboarding flow asks "what will you use PrivoVoice for?"
// and maps each answer to ONE recommended model (plus a few good alternates),
// framed by intent rather than by raw spec sheet. Every model id referenced here
// is a real `ModelCatalog` id; a drift-guard test (UseCaseProfilesTests) enforces
// that no id can dangle.
//
// The categories below are distilled from a survey of how people actually use
// speech-to-text / dictation and what each group optimizes for:
//
//   - "Talk to your computer" / coding docs / AI-prompt dictation — speed &
//     live feel come first; punctuation and casing barely matter because the
//     text is a means to an end (a prompt, a comment, a search). Devs dictate
//     docstrings, commit messages and prompts rather than raw syntax.
//       Source: https://speechify.com/blog/ai-dictation-for-developers-coders-voice-coding-2026/
//   - Everyday notes & messaging — balanced speed + accuracy for quick capture;
//     people speak at ~125–150 wpm vs ~40 wpm typing, so throughput wins.
//       Source: https://www.getvoibe.com/resources/use-cases/
//   - Polished writing (email, docs) — accuracy AND clean punctuation/casing
//     matter because the output ships as-is; light proofreading, not rewriting.
//       Source: https://speechify.com/blog/what-is-the-difference-between-voice-typing-ai-dictation-and-transcription/
//   - Multilingual users — need coverage across (here, European) languages.
//       Source: https://www.getvoibe.com/resources/use-cases/
//   - Maximum accuracy (professional / medical / legal / accessibility) — lowest
//     word-error rate is non-negotiable; providers are accountable for accuracy.
//       Sources: https://www.notta.ai/en/blog/medical-dictation-apps ,
//                https://weesperneonflow.ai/en/blog/2025-10-19-voice-dictation-accessibility-dyslexia-disabilities-guide/
//
// Mapping rationale (see ModelCatalog for the signals):
//   fast-capture   → Parakeet TDT v2 (English) / v3 (other European langs); Nemotron for a live word-by-word feel
//   everyday       → Parakeet TDT v2 (English) / v3 (other European langs) — fast + accurate all-rounder
//   polished       → Canary-Qwen (best punctuation + casing, WER 5.06)
//   multilingual   → Parakeet TDT v3 (25 European languages, fast, WER 5.66)
//   max-accuracy   → Granite Speech NAR (lowest WER we ship, 4.95)
//
// "Depending on language": fast-capture and everyday rank Parakeet v2 first (best
// English accuracy) then v3 (25 European languages); `recommendedModel(for:)`
// resolves to the highest-ranked model that actually covers the user's language —
// so English speakers get v2 and, say, German speakers get v3, from the same list.

import Foundation

/// One onboarding "what will you use this for?" bucket, framed by intent, with a
/// single recommended model and optional alternates. All copy here is
/// user-facing. Model ids MUST match `ModelCatalog` ids.
public struct UseCaseProfile: Identifiable, Sendable, Hashable {
    /// Stable slug (e.g. "fast-capture"). Safe to persist as the user's choice.
    public let id: String
    /// Short intent-framed heading for a card, e.g. "Talk to your computer".
    public let title: String
    /// One short line under the title.
    public let tagline: String
    /// One or two sentences: who this is for and what it optimizes.
    public let summary: String
    /// SF Symbol name for the card icon.
    public let systemImage: String
    /// The single recommended model. MUST equal a `ModelCatalog` id.
    public let recommendedModelID: String
    /// Zero or more good alternates. Each MUST equal a `ModelCatalog` id.
    public let alsoGoodModelIDs: [String]
    /// Why the recommended model fits this use case (user-facing).
    public let rationale: String

    public init(
        id: String,
        title: String,
        tagline: String,
        summary: String,
        systemImage: String,
        recommendedModelID: String,
        alsoGoodModelIDs: [String],
        rationale: String
    ) {
        self.id = id
        self.title = title
        self.tagline = tagline
        self.summary = summary
        self.systemImage = systemImage
        self.recommendedModelID = recommendedModelID
        self.alsoGoodModelIDs = alsoGoodModelIDs
        self.rationale = rationale
    }

    /// The resolved recommended spec, or `nil` if the id ever drifts.
    public var recommendedModel: ModelSpec? { ModelCatalog.spec(id: recommendedModelID) }

    /// The resolved alternate specs, skipping any that fail to resolve.
    public var alsoGoodModels: [ModelSpec] { alsoGoodModelIDs.compactMap(ModelCatalog.spec) }

    /// Candidate specs in rank order: the recommended model first, then the
    /// alternates. Skips any id that fails to resolve.
    public var rankedModels: [ModelSpec] {
        ([recommendedModelID] + alsoGoodModelIDs).compactMap(ModelCatalog.spec)
    }

    /// The recommended model for a specific language: the highest-ranked candidate
    /// whose languages include `languageCode` (e.g. Parakeet v2 for "en", v3 for
    /// "de"), falling back to the plain recommended model when none cover it.
    /// `languageCode` is an ISO-639 code like "en" or "de".
    public func recommendedModel(for languageCode: String) -> ModelSpec? {
        rankedModels.first { $0.languages.contains { $0.code == languageCode } }
            ?? recommendedModel
    }
}

/// The onboarding use-case catalog. Order = the order cards appear.
public enum UseCaseCatalog {
    public static let all: [UseCaseProfile] = [
        UseCaseProfile(
            id: "fast-capture",
            title: "Talk to your computer",
            tagline: "Speed first — prompts, comments, quick commands.",
            summary: """
            For dictating into AI chats, code comments, and search bars, where you \
            want fast, low-fuss text and don't mind fixing the odd capital later.
            """,
            systemImage: "bolt.fill",
            recommendedModelID: "parakeet-tdt-0.6b-v2",
            alsoGoodModelIDs: ["parakeet-tdt-0.6b-v3", "nemotron-speech-streaming-en-0.6b"],
            rationale: """
            Parakeet TDT is fast and low-fuss with a tiny footprint — v2 for English, \
            v3 when you speak another European language. If you'd rather see words \
            land one-by-one as you speak, Nemotron Streaming is a great alternative.
            """
        ),
        UseCaseProfile(
            id: "everyday",
            title: "Everyday notes & messages",
            tagline: "A fast, accurate all-rounder.",
            summary: """
            For jotting notes, firing off messages, and capturing thoughts on the \
            go. The balanced pick when you just want to talk instead of type.
            """,
            systemImage: "note.text",
            recommendedModelID: "parakeet-tdt-0.6b-v2",
            alsoGoodModelIDs: ["parakeet-tdt-0.6b-v3", "whisper-large-v3-turbo"],
            rationale: """
            Parakeet TDT is the sweet spot of speed and accuracy with the smallest \
            footprint — v2 has the best English accuracy of the small tier (WER 5.39), \
            and v3 covers 25 European languages if you speak something other than English.
            """
        ),
        UseCaseProfile(
            id: "polished",
            title: "Polished writing",
            tagline: "Email and docs that ship as-is.",
            summary: """
            For email, documents, and anything where the text goes out the way you \
            spoke it. Optimized for clean punctuation and correct casing so you \
            proofread instead of reformat.
            """,
            systemImage: "doc.richtext",
            recommendedModelID: "canary-qwen-2.5b",
            alsoGoodModelIDs: ["granite-speech-4.1-2b-nar", "whisper-large-v3"],
            rationale: """
            Canary-Qwen produces the best punctuation and casing we ship, so dictated \
            prose reads like written prose. It shines on recorded and file audio; for \
            long live sessions it favors accuracy over instant feedback.
            """
        ),
        UseCaseProfile(
            id: "multilingual",
            title: "Multilingual",
            tagline: "25 European languages, one model.",
            summary: """
            For speaking German, French, Spanish, Portuguese, Italian and 20 more \
            European languages — no switching models between tongues.
            """,
            systemImage: "globe",
            recommendedModelID: "parakeet-tdt-0.6b-v3",
            alsoGoodModelIDs: ["granite-speech-4.1-2b-nar"],
            rationale: """
            Parakeet TDT v3 covers 25 European languages with the same fast passes and \
            small footprint as its English sibling (WER 5.66) — the widest language \
            reach we ship without giving up speed.
            """
        ),
        UseCaseProfile(
            id: "max-accuracy",
            title: "Maximum accuracy",
            tagline: "Every word counts.",
            summary: """
            For professional, medical, legal, and accessibility work where the lowest \
            error rate is non-negotiable and you want the least editing afterward.
            """,
            systemImage: "target",
            recommendedModelID: "granite-speech-4.1-2b-nar",
            alsoGoodModelIDs: ["canary-qwen-2.5b", "whisper-large-v3"],
            rationale: """
            Granite Speech NAR has the lowest word-error rate we ship (WER 4.95) while \
            still balancing live and file use. It's the most accurate transcriber in \
            the catalog when precision outweighs footprint.
            """
        ),
    ]

    /// Look up a profile by its stable id.
    public static func profile(id: String) -> UseCaseProfile? {
        all.first { $0.id == id }
    }

    /// Resolve the recommended model spec for a use-case id, via `ModelCatalog`.
    public static func recommendedModel(for id: String) -> ModelSpec? {
        guard let profile = profile(id: id) else { return nil }
        return ModelCatalog.spec(id: profile.recommendedModelID)
    }

    /// Language-aware recommended model for a use-case id — resolves Parakeet v2 vs
    /// v3 (and similar) by the given ISO-639 language code.
    public static func recommendedModel(for id: String, languageCode: String) -> ModelSpec? {
        profile(id: id)?.recommendedModel(for: languageCode)
    }
}
