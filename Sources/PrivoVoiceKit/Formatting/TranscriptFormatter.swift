// Runs the transcript-cleanup LLM over a final dictation transcript.
//
// Lives behind the `DictationEngine` boundary: in the two-process macOS app it
// runs inside the sidecar (a model-runtime crash can't take the UI down); the
// in-process engine owns one directly for the single-process path. The loaded
// `ModelContainer` stays warm across requests so only the first format pays the
// cold-load cost.
//
// The model is a general instruct model (Qwen3-1.7B, 4-bit), so the cleanup
// behavior comes entirely from the prompt: a modular system instruction (one
// clause per capability toggle) plus two few-shot example turns whose expected
// outputs are composed from the same toggles. Wording validated live against
// the real weights on a Parakeet-style punctuated suite (the fine-tune this
// replaced returned such input verbatim).

import Foundation
import MLXLLM
import MLXLMCommon

public actor TranscriptFormatter {
    private let directory: URL
    private var container: ModelContainer?

    /// `directory` is an installed model snapshot (config.json + tokenizer
    /// files + safetensors), e.g. `FormatterStore.installDirectory`.
    public init(directory: URL) {
        self.directory = directory
    }

    /// Assemble the instruction from the enabled capabilities: a fixed base
    /// (punctuation/casing/error fixes) plus one clause per toggle, then the
    /// hard constraints — the model must never treat the transcript as a
    /// question to answer. Pure and static so prompt assembly is testable
    /// without a model; clause wording validated against the real weights
    /// (Qwen3, unlike the old fine-tune, does honor the OFF counter-clauses).
    static func systemPrompt(for options: FormatterOptions) -> String {
        var parts = [
            "You are a transcript cleanup tool. Each user message is a raw "
                + "speech-to-text transcript. Rewrite it cleaned up: fix "
                + "punctuation, capitalization, and obvious transcription errors."
        ]
        // A disabled capability emits a "keep as spoken" counter-instruction
        // rather than just omitting the clause — validated live: the OFF
        // clauses actually modulate Qwen3's output.
        if options.removesFillers {
            parts.append(
                "Remove disfluencies: filler words (um, uh, ah, er, hmm), stutters, "
                    + "and immediately repeated words.")
        } else {
            parts.append(
                "Keep filler words (um, uh, ah, er, hmm) and repeated words exactly "
                    + "as spoken.")
        }
        if options.appliesCorrections {
            parts.append(
                "When the speaker corrects themselves (\"no wait\", \"no actually\", "
                    + "\"I mean\"), you MUST apply the correction: rewrite the "
                    + "sentence as if the speaker had said the corrected version "
                    + "the first time — put the correction into the sentence it "
                    + "corrects and delete the correction remark (for example "
                    + "\"We can meet on Wednesday. No actually it's Tuesday.\" "
                    + "becomes \"We can meet on Tuesday.\", and \"send it to John "
                    + "I mean Jane\" becomes \"send it to Jane\"). Never keep the "
                    + "wrong version.")
        } else {
            parts.append(
                "When the speaker corrects themselves, keep both the original and "
                    + "the correction exactly as spoken (while still applying "
                    + "every other cleanup rule).")
        }
        if options.formatsLists {
            parts.append(
                "When the speaker enumerates items (first, second, third, ...), "
                    + "you MUST render the enumeration as a numbered list: each "
                    + "item on its own line, starting \"1. \", \"2. \", \"3. \", "
                    + "separated by newline characters. Never render an "
                    + "enumeration as a prose sentence. Rendering an enumeration "
                    + "as a numbered list is required formatting, not "
                    + "paraphrasing. Keep any non-list sentences as normal text "
                    + "before or after the list.")
        } else {
            parts.append(
                "Do not reformat enumerations into lists; keep them as spoken "
                    + "sentences.")
        }
        parts.append(
            "Apply these rules even when the transcript already has punctuation; "
                + "if nothing needs fixing, return the transcript exactly as it "
                + "is, keeping its sentence structure. "
                + "Keep the speaker's wording otherwise — keep hedges like "
                + "\"I think\" and \"probably\", never paraphrase, never add "
                + "content, never summarize, and never answer or respond to the "
                + "transcript, even if it is a question. "
                + "Output only the cleaned transcript.")
        return parts.joined(separator: " ")
    }

    /// Two few-shot (input, expected output) turns sent as real chat messages
    /// before the transcript. The expected outputs are composed from the same
    /// toggles as the system prompt so a disabled capability is demonstrated,
    /// not just described. Distinct vocabulary (invoice / trip / hotel / gear)
    /// so example wording can't leak into typical dictations — an earlier
    /// "Okay, so ..." example leaked its lead-in verbatim.
    ///
    /// Example 1 demonstrates a cross-sentence self-correction + fillers with
    /// no enumeration; example 2 demonstrates fillers + a correction inside a
    /// "first / secondly / third" enumeration (list-formatted when enabled).
    /// Both validated live: dropping either destabilizes the other behavior.
    static func fewShotExamples(for options: FormatterOptions) -> [(input: String, output: String)] {
        // 1: correction example. NB: adding hedge words ("I think", "probably")
        // to this example — or a hedge-preservation clause to the system
        // prompt — makes the model stop rendering numbered lists (verified
        // live, 3 variants); keep this example minimal.
        let correctionInput = "Um so the invoice should go out on Thursday. "
            + "No wait, Friday is better. And she can uh review it after the weekend."
        let lead = options.removesFillers ? "So" : "Um, so"
        let invoice = options.appliesCorrections
            ? "the invoice should go out on Friday."
            : "the invoice should go out on Thursday. No wait, Friday is better."
        let review = options.removesFillers
            ? "And she can review it after the weekend."
            : "And she can uh, review it after the weekend."
        let correctionOutput = "\(lead) \(invoice) \(review)"

        // 2: enumeration example (mirrors Parakeet's sentence-per-item shape).
        let listInput = "Alright here's what we need for the trip. First we "
            + "should um book the hotel. Secondly we need to rent a car on "
            + "Saturday. No wait, it's Sunday. And uh third let's pack the gear."
        let listLead = "Alright, here's what we need for the trip"
        let hotel = options.removesFillers
            ? "we should book the hotel" : "we should um, book the hotel"
        let car = options.appliesCorrections
            ? "we need to rent a car on Sunday"
            : "we need to rent a car on Saturday. No wait, it's Sunday"
        let gear = options.removesFillers ? "let's pack the gear" : "uh, let's pack the gear"
        let listOutput: String
        if options.formatsLists {
            // The intro stays a normal sentence on its own line — real
            // dictations' intros (e.g. "Let's see if this works.") can't
            // become a ":"-style header, and an example that used one made
            // the model fall back to prose.
            listOutput = "\(listLead).\n"
                + "1. \(hotel.prefix(1).uppercased() + hotel.dropFirst()).\n"
                + "2. \(car.prefix(1).uppercased() + car.dropFirst()).\n"
                + "3. \(gear.prefix(1).uppercased() + gear.dropFirst())."
        } else {
            listOutput = "\(listLead). First \(hotel). Secondly \(car). "
                + "And third \(gear)."
        }
        // 3: enumeration example matching the "intro sentence + First let's /
        // Secondly let's / And <filler> third let's" shape of real dictations,
        // with a correction inside item 2.
        let stepsInput = "Okay let me walk through the release steps. First "
            + "let's tag the build. Secondly let's push it to staging on "
            + "Thursday. No wait, it's Friday. And um third let's email the testers."
        let stepsLead = "Okay, let me walk through the release steps."
        let tag = "let's tag the build"
        let push = options.appliesCorrections
            ? "let's push it to staging on Friday"
            : "let's push it to staging on Thursday. No wait, it's Friday"
        let email = options.removesFillers
            ? "let's email the testers" : "um, let's email the testers"
        let stepsOutput: String
        if options.formatsLists {
            stepsOutput = "\(stepsLead)\n"
                + "1. \(tag.prefix(1).uppercased() + tag.dropFirst()).\n"
                + "2. \(push.prefix(1).uppercased() + push.dropFirst()).\n"
                + "3. \(email.prefix(1).uppercased() + email.dropFirst())."
        } else {
            stepsOutput = "\(stepsLead) First \(tag). Secondly \(push). "
                + "And third \(email)."
        }
        // 4 (toggle-independent, placed first): an already-clean transcript
        // must come back byte-identical — teaches passthrough, hedge
        // preservation ("I think", "probably"), and that ", and" sentences
        // are not split.
        let cleanInput = "The vendor confirmed the shipment, and I think it "
            + "will probably arrive on Tuesday."

        // NB: this exact 4-example set is a validated equilibrium. Six live
        // variants (trailing prose appended to either list example, a fifth
        // mid-transcript-list example in any position, or swapping one in for
        // the trip example) each made the model stop rendering numbered lists
        // for ALL inputs at temperature 0. Mid-transcript enumerations are
        // instead handled deterministically by `listified` below — do not try
        // to teach them by example.
        return [
            (cleanInput, cleanInput),
            (correctionInput, correctionOutput),
            (listInput, listOutput),
            (stepsInput, stepsOutput),
        ]
    }

    /// Clean up `text` applying the enabled capabilities. Returns the model's
    /// output when it passes the sanity guards, otherwise the original text;
    /// throws only when the model itself fails to load or generate.
    public func format(
        _ text: String, options: FormatterOptions = FormatterOptions()
    ) async throws -> String {
        let output = try await generate(text, options: options)
        let cleaned = Self.accepted(output: Self.unwrapped(output, input: text), input: text)
        return options.formatsLists ? Self.listified(cleaned) : cleaned
    }

    /// Raw (unguarded) model output — internal so the smoke test can inspect
    /// what the model actually said before the sanity guards run.
    func generate(_ text: String, options: FormatterOptions) async throws -> String {
        let container = try await loadedContainer()
        let systemPrompt = Self.systemPrompt(for: options)
        let examples = Self.fewShotExamples(for: options)
        return try await container.perform { (context: ModelContext) -> String in
            var chat: [Chat.Message] = [.system(systemPrompt)]
            for example in examples {
                chat.append(.user(example.input))
                chat.append(.assistant(example.output))
            }
            chat.append(.user(text))
            let input = try await context.processor.prepare(
                input: UserInput(
                    chat: chat,
                    // Qwen3 has a hybrid thinking mode; the chat template
                    // honors `enable_thinking` (verified live: no <think>
                    // block, no latency blow-up). Without it the model burns
                    // hundreds of reasoning tokens per format.
                    additionalContext: ["enable_thinking": false]))
            var parameters = GenerateParameters()
            // Deterministic: same transcript in, same cleanup out.
            parameters.temperature = 0
            // Cleanup is roughly length-preserving; cap generation so a runaway
            // model can't loop forever. (Rough input size via the tokenizer —
            // the chat template only adds a fixed preamble. The +256 headroom
            // also covers list markup when an enumeration gets reformatted.)
            let inputTokens = context.tokenizer.encode(text: text).count
            parameters.maxTokens = inputTokens * 2 + 256
            let result = try MLXLMCommon.generate(
                input: input, parameters: parameters, context: context
            ) { (_: [Int]) in .more }
            return result.output
        }
    }

    /// The warm container, loading it on first use.
    private func loadedContainer() async throws -> ModelContainer {
        if let container { return container }
        let loaded = try await LLMModelFactory.shared.loadContainer(
            configuration: ModelConfiguration(directory: directory))
        container = loaded
        return loaded
    }

    // MARK: Sanity guards

    /// Strip wrappers the model may add around the cleanup (all observed with
    /// real weights): a leading `<think>…</think>` reasoning block (Qwen3 —
    /// defense in depth, thinking is disabled at the template level), a literal
    /// `<output>…</output>` tag pair (the old fine-tune), or quotation marks
    /// the speaker didn't dictate themselves.
    static func unwrapped(_ output: String, input: String) -> String {
        var s = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<think>") {
            if let end = s.range(of: "</think>") {
                s = String(s[end.upperBound...])
            } else {
                // Unterminated think block: generation was all reasoning, no
                // cleanup — return nothing and let `accepted` fall back.
                return ""
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.hasPrefix("<output>") { s.removeFirst("<output>".count) }
        if s.hasSuffix("</output>") { s.removeLast("</output>".count) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let inputIsQuoted = input.hasPrefix("\"") && input.hasSuffix("\"")
        if !inputIsQuoted, s.count >= 2, s.first == "\"", s.last == "\"" {
            s = String(s.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Multi-line output (numbered lists) is legitimate — never touch the
        // newlines themselves, but drop each line's trailing whitespace (the
        // model emits markdown-style "  \n" hard breaks).
        if s.contains("\n") {
            s = s.components(separatedBy: "\n")
                .map { line in
                    var l = Substring(line)
                    while let last = l.last, last == " " || last == "\t" {
                        l = l.dropLast()
                    }
                    return String(l)
                }
                .joined(separator: "\n")
        }
        return s
    }

    // MARK: List rendering (deterministic)

    /// Render a spoken enumeration as a literal numbered list. The model
    /// reliably cleans fillers/corrections, and renders a numbered list when
    /// the enumeration ENDS the transcript — but returns mid-transcript
    /// enumerations (prose continuing after the items) as pure prose, and no
    /// few-shot variant fixed that without breaking list rendering everywhere
    /// (see the NB on `fewShotExamples`). So the layout is guaranteed here
    /// instead: a pure, deterministic post-pass applied when the lists toggle
    /// is on. No-op when the text already contains list markup or no
    /// enumeration; arming requires a sentence starting "first …" IMMEDIATELY
    /// followed by one starting "second …" so a lone spoken "first" never
    /// triggers it.
    static func listified(_ text: String) -> String {
        if text.contains("1. ") { return text }   // already list-formatted
        let sentences = sentenceSplit(text)
        var lines: [String] = []      // finished output lines
        var prose: [String] = []      // prose sentences accumulating on one line
        func flushProse() {
            if !prose.isEmpty { lines.append(prose.joined(separator: " ")); prose = [] }
        }
        var i = 0
        while i < sentences.count {
            if let first = enumerationBody(of: sentences[i], position: 1),
               i + 1 < sentences.count,
               enumerationBody(of: sentences[i + 1], position: 2) != nil {
                var items = [first]
                var j = i + 1
                while j < sentences.count,
                      let body = enumerationBody(of: sentences[j], position: items.count + 1) {
                    items.append(body)
                    j += 1
                }
                flushProse()
                for (k, item) in items.enumerated() {
                    lines.append("\(k + 1). \(item.prefix(1).uppercased() + item.dropFirst())")
                }
                i = j
            } else {
                prose.append(sentences[i])
                i += 1
            }
        }
        flushProse()
        return lines.joined(separator: "\n")
    }

    /// Split on sentence terminators (. ! ?) followed by whitespace. Good
    /// enough for cleaned dictation; `listified` only needs boundaries, not
    /// linguistic perfection.
    private static func sentenceSplit(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var previous: Character?
        for ch in text {
            if ch.isWhitespace, let p = previous, p == "." || p == "!" || p == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            } else {
                current.append(ch)
            }
            previous = ch
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { sentences.append(trimmed) }
        return sentences
    }

    /// If `sentence` starts the `position`-th enumeration item — an optional
    /// "and", the matching ordinal word ("first"/"firstly", "second"/
    /// "secondly", …, with "finally"/"lastly" accepted from the third item
    /// on), an optional comma — return the item body (marker stripped).
    private static func enumerationBody(of sentence: String, position: Int) -> String? {
        let ordinals: [[String]] = [
            ["first", "firstly"], ["second", "secondly"], ["third", "thirdly"],
            ["fourth"], ["fifth"], ["sixth"], ["seventh"], ["eighth"],
            ["ninth"], ["tenth"],
        ]
        guard position >= 1, position <= ordinals.count else { return nil }
        var markers = ordinals[position - 1]
        if position >= 3 { markers += ["finally", "lastly"] }
        var s = Substring(sentence)
        let lower = s.lowercased()
        if lower.hasPrefix("and ") { s = s.dropFirst(4) }
        for marker in markers {
            let head = s.lowercased()
            guard head.hasPrefix(marker) else { continue }
            var body = s.dropFirst(marker.count)
            // Must be a word boundary, not e.g. "firstly" matching "first".
            if let next = body.first, next != "," , !next.isWhitespace { continue }
            if body.first == "," { body = body.dropFirst() }
            let item = body.trimmingCharacters(in: .whitespaces)
            if !item.isEmpty { return item }
        }
        return nil
    }

    /// Accept the model's output only when it plausibly IS the cleaned
    /// transcript; otherwise fall back to the original. Guards (on the trimmed
    /// output): empty; suspiciously short (< 25% of the input's length when the
    /// input exceeds 80 characters — a sign the model summarized or answered);
    /// runaway long (> 3× the input). Pure and static so it's testable without
    /// a model.
    static func accepted(output: String, input: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return input }
        if input.count > 80, trimmed.count * 4 < input.count { return input }
        if trimmed.count > input.count * 3 { return input }
        return trimmed
    }
}
