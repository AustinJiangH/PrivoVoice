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
import MLX
import MLXLLM
import MLXLMCommon
import os

public actor TranscriptFormatter {
    private let directory: URL
    private var container: ModelContainer?
    /// Tail of the serialized generation queue — see `serialized(_:)`.
    private var queueTail: Task<Void, Never>?
    /// KV state of the most recent request's full prompt — see `generate`.
    private let prefixCache = PrefixCache()

    /// Per-request perf one-liner (prompt/reused tokens, prefill/decode ms) so
    /// "formatting feels slow" is diagnosable from the unified log.
    private static let log = Logger(subsystem: "com.privovoice.helper", category: "formatter")

    /// `directory` is an installed model snapshot (config.json + tokenizer
    /// files + safetensors), e.g. `FormatterStore.installDirectory`.
    public init(directory: URL) {
        self.directory = directory
    }

    /// Release the loaded model container, the prompt-prefix KV cache, and
    /// MLX's buffer reuse cache (~1 GB total). Explicit rather than relying on
    /// the owner dropping its reference: the serialized-queue task handles can
    /// keep the actor shell alive past the drop (deferred deallocation), which
    /// would silently keep the weights resident. Queued behind any in-flight
    /// generation/warm-up (a warm-up runs off the sidecar's serial loop, so an
    /// unload CAN arrive mid-load) so the model and prompt cache are never
    /// torn down mid-use; the next format reloads from scratch.
    public func unload() async {
        _ = try? await serialized { [self] in await dropResidentState() }
    }

    /// The synchronous teardown behind `unload()` — actor-isolated, so it can
    /// never interleave with the actor hops of a queued generation.
    private func dropResidentState() {
        container = nil
        prefixCache.reset()
        // Drop the queue-tail handle too: it's what can pin the last op's
        // captures (including self) alive after the work is done.
        queueTail = nil
        // Freed weight buffers land in MLX's reuse cache (RSS stays put);
        // clearing the cache is what actually returns them to the OS.
        GPU.clearCache()
    }

    /// The KV (attention) state of the fixed prompt preamble (system prompt +
    /// few-shots + chat-template header, ~600 tokens ≈ 0.3 s of prefill),
    /// computed once per `FormatterOptions` and reused by every request: each
    /// format rewinds the cache to `preambleTokens.count` and prefills only its
    /// own user turn. The preamble KV is filled SEPARATELY from any request
    /// (see `buildAnchor`) so every request — including the very first — runs
    /// the exact same suffix computation: at temperature 0 the same transcript
    /// always formats to the same bytes. `@unchecked Sendable`: confined to the
    /// serialized generation path.
    private final class PrefixCache: @unchecked Sendable {
        var options: FormatterOptions?
        var preambleTokens: [Int] = []
        var cache: [KVCache] = []
        func reset() {
            options = nil
            preambleTokens = []
            cache = []
        }
    }

    /// Timing breakdown of one generation (internal: probes/tests + the perf log).
    struct GenerationStats: Sendable {
        var promptTokenCount: Int      // full prompt, preamble included
        var reusedTokenCount: Int      // served from the prefix cache
        var prefillTime: TimeInterval  // suffix prefill (incl. graph setup)
        var decodeTokenCount: Int
        var decodeTime: TimeInterval
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
    /// throws only when the model itself fails to load or generate — or when
    /// the caller's task was cancelled (the session's polish timeout), in
    /// which case a partially-decoded output must never be delivered.
    public func format(
        _ text: String, options: FormatterOptions = FormatterOptions()
    ) async throws -> String {
        let output = try await generate(text, options: options)
        try Task.checkCancellation()   // a stopped-early generation is partial
        let cleaned = Self.accepted(output: Self.unwrapped(output, input: text), input: text)
        return options.formatsLists ? Self.listified(cleaned) : cleaned
    }

    /// Best-effort warm-up: load the model, run a 1-token generation (JITs the
    /// Metal kernels), and leave the prompt-prefix KV cache primed with the
    /// system + few-shot preamble — so the first real format only pays its own
    /// suffix prefill + decode (~0.1–0.3 s) instead of load + full prefill
    /// (~1.5 s). Idempotent and cheap when already warm (the preamble is
    /// served from the prefix cache); safe to call concurrently with formats
    /// (everything funnels through the serialized generation queue).
    public func prewarm(options: FormatterOptions = FormatterOptions()) async throws {
        _ = try await generateWithStats("Warm up.", options: options, maxTokensLimit: 1)
    }

    /// Raw (unguarded) model output — internal so the smoke test can inspect
    /// what the model actually said before the sanity guards run.
    func generate(_ text: String, options: FormatterOptions) async throws -> String {
        try await generateWithStats(text, options: options).output
    }

    /// `generate` plus the timing breakdown (internal for probes/tests).
    func generateWithStats(
        _ text: String, options: FormatterOptions, maxTokensLimit: Int? = nil
    ) async throws -> (output: String, stats: GenerationStats) {
        try await serialized { [self] in
            // Cancellation-responsive: don't start (or cold-load) a generation
            // whose result nobody will read — the session already fell back to
            // the raw transcript.
            try Task.checkCancellation()
            let container = try await loadedContainer()
            let systemPrompt = Self.systemPrompt(for: options)
            let examples = Self.fewShotExamples(for: options)
            let prefixCache = self.prefixCache
            let result = try await container.perform {
                (context: ModelContext) -> (output: String, stats: GenerationStats) in
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
                // Larger prefill windows shave a little off a cold (uncached)
                // preamble prefill; the whole prompt then runs in one window.
                parameters.prefillStepSize = 1024
                // Cleanup is roughly length-preserving; cap generation so a runaway
                // model can't loop forever. (Rough input size via the tokenizer —
                // the chat template only adds a fixed preamble. The +256 headroom
                // also covers list markup when an enumeration gets reformatted.)
                let inputTokens = context.tokenizer.encode(text: text).count
                parameters.maxTokens = min(
                    maxTokensLimit ?? Int.max, inputTokens * 2 + 256)
                // Make sure the preamble KV state exists for these options;
                // any anchor failure just means this request full-prefills.
                if prefixCache.options != options || prefixCache.cache.isEmpty {
                    do {
                        try await Self.buildAnchor(
                            context: context, chat: Array(chat.dropLast()),
                            options: options, parameters: parameters,
                            into: prefixCache)
                    } catch {
                        prefixCache.reset()
                    }
                }
                do {
                    return try Self.generate(
                        input: input, parameters: parameters, context: context,
                        reusing: prefixCache)
                } catch {
                    // Robustness: any cached-path failure falls back to one
                    // full prefill with a fresh cache.
                    prefixCache.reset()
                    return try Self.generate(
                        input: input, parameters: parameters, context: context,
                        reusing: prefixCache)
                }
            }
            let s = result.stats
            Self.log.info("""
                format: prompt=\(s.promptTokenCount) reused=\(s.reusedTokenCount) \
                prefill=\(Int(s.prefillTime * 1000))ms \
                decode=\(s.decodeTokenCount)tok/\(Int(s.decodeTime * 1000))ms \
                (\(Int(Double(s.decodeTokenCount) / max(s.decodeTime, 0.001)))tok/s)
                """)
            return result
        }
    }

    /// Fill `store` with the KV state of the fixed preamble for `options`.
    ///
    /// The preamble's token-exact boundary comes from rendering the chat with
    /// two different one-character user turns and taking the shared prefix —
    /// robust against chat-template details (BOS handling, generation header)
    /// without re-implementing the template. The preamble is then prefilled on
    /// its own, in fixed `prefillStepSize` chunks, so its KV values never
    /// depend on any particular request. ~0.3 s, paid once per options change
    /// (or at `prewarm`), not per format.
    private static func buildAnchor(
        context: ModelContext, chat: [Chat.Message], options: FormatterOptions,
        parameters: GenerateParameters, into store: PrefixCache
    ) async throws {
        store.reset()
        func render(_ userText: String) async throws -> [Int] {
            let input = try await context.processor.prepare(
                input: UserInput(
                    chat: chat + [.user(userText)],
                    additionalContext: ["enable_thinking": false]))
            return input.text.tokens.asArray(Int.self)
        }
        let a = try await render("0")
        let b = try await render("1")
        let n = Self.sharedPrefixLength(a, b)
        guard n > 0 else { return }   // template renders nothing stable — skip caching

        let preamble = Array(a[0..<n])
        let cache = context.model.newCache(parameters: parameters)
        let step = max(256, parameters.prefillStepSize)
        var pos = 0
        while pos < preamble.count {
            let end = min(pos + step, preamble.count)
            _ = context.model(
                MLXArray(Array(preamble[pos..<end]))[.newAxis], cache: cache)
            eval(cache.flatMap { $0.innerState() })
            pos = end
        }
        store.options = options
        store.preambleTokens = preamble
        store.cache = cache
    }

    /// Length of the shared leading run of two token sequences — the fixed
    /// preamble when applied to two renders of the same chat that differ only
    /// in the final user turn. Pure and static for testability.
    static func sharedPrefixLength(_ a: [Int], _ b: [Int]) -> Int {
        var i = 0
        let limit = min(a.count, b.count)
        while i < limit && a[i] == b[i] { i += 1 }
        return i
    }

    /// Run one generation. When the prompt starts with the anchored preamble
    /// (the common case — see `buildAnchor`), the cache is rewound to the
    /// preamble and only the user turn is prefilled; otherwise (no anchor,
    /// template drift, an over-long transcript…) the whole prompt is prefilled
    /// against a throwaway cache. Both paths produce the same kind of result —
    /// the cache is purely a latency optimization.
    private static func generate(
        input: LMInput, parameters: GenerateParameters, context: ModelContext,
        reusing store: PrefixCache
    ) throws -> (output: String, stats: GenerationStats) {
        let fullTokens = input.text.tokens.asArray(Int.self)

        // Reuse requires a rewindable cache holding at least the preamble, a
        // prompt that extends the preamble by at least one token (the model
        // needs a final token to produce logits), and a byte-stable preamble.
        var reused = 0
        var cache: [KVCache] = []
        let n = store.preambleTokens.count
        if n > 0, !store.cache.isEmpty,
           store.cache.allSatisfy(\.isTrimmable),
           store.cache[0].offset >= n,
           fullTokens.count > n,
           Array(fullTokens[0..<n]) == store.preambleTokens {
            let rewind = store.cache[0].offset - n
            if rewind > 0 { for c in store.cache { _ = c.trim(rewind) } }
            reused = n
            cache = store.cache
        } else {
            store.reset()   // stale/mismatched anchor: re-anchor on the next call
            cache = context.model.newCache(parameters: parameters)
        }

        let suffixInput = LMInput(tokens: MLXArray(Array(fullTokens[reused...])))
        let started = Date()
        let iterator = try TokenIterator(
            input: suffixInput, model: context.model, cache: cache,
            parameters: parameters)
        // The didGenerate callback is the per-token hook: stopping there when
        // the task is cancelled bounds a no-longer-wanted generation to one
        // more token instead of the full decode (MLX itself ignores
        // cancellation). The partial output is discarded by `format`'s
        // post-generate cancellation check.
        let result = MLXLMCommon.generate(
            input: suffixInput, context: context, iterator: iterator
        ) { (_: [Int]) in Task.isCancelled ? .stop : .more }
        // NB: when reusing, the generated turn stays in the cache until the
        // next request rewinds back to the preamble.

        let wall = Date().timeIntervalSince(started)
        let stats = GenerationStats(
            promptTokenCount: fullTokens.count,
            reusedTokenCount: reused,
            prefillTime: max(0, wall - result.generateTime),
            decodeTokenCount: result.generationTokenCount,
            decodeTime: result.generateTime)
        return (result.output, stats)
    }

    /// Run `op` after all previously queued generation work. Actor methods are
    /// reentrant at `await`s, so without this a warm-up and a format (or two
    /// formats) could interleave and fight over the prompt cache or double-load
    /// the model container.
    ///
    /// Cancellation is forwarded into the queued (unstructured) task so a
    /// caller whose task gets cancelled — the session's polish timeout — makes
    /// `op` observe `Task.isCancelled` (checked before generation and per
    /// decoded token) instead of running to completion unobserved.
    private func serialized<T: Sendable>(
        _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previous = queueTail
        let task = Task<T, Error> {
            await previous?.value
            return try await op()
        }
        queueTail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// The warm container, loading it on first use. Only called from the
    /// serialized generation path, so it cannot double-load.
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
        // Only strip a wrapping quote pair the model added when the INPUT
        // contains no quote at all. If the speaker dictated any quotes, a
        // leading+trailing pair may be two different quoted spans (e.g. edge
        // fillers stripped around «"yes" she said "no"») — stripping would
        // unbalance the output.
        if !input.contains("\""), s.count >= 2, s.first == "\"", s.last == "\"" {
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
    /// is on. Arming requires a sentence starting "first …" IMMEDIATELY
    /// followed by one starting "second …" so a lone spoken "first" never
    /// triggers it.
    ///
    /// Ordinal words are lexically ambiguous ("First Street is closed",
    /// "second thoughts", "First of all"), so the pass is parse-clean-or-bail:
    /// every corruption becomes a benign miss.
    ///   • No-op on any multi-line text — the model already chose a layout
    ///     (dash bullets, a numbered list, paragraphs); flattening it back
    ///     through the prose pass would corrupt it.
    ///   • Known non-enumeration continuations ("first of all", "second
    ///     thoughts", …) are not markers — those sentences stay prose.
    ///   • Every detected item in a run must parse cleanly: the marker strip
    ///     leaves a body that started lowercase in the original (or with the
    ///     pronoun "I"), and no item body ends in an abbreviation ("ask Dr."
    ///     is a bad sentence split, not an item). If ANY item in any run
    ///     fails, the ENTIRE input is returned unchanged — a half-stripped
    ///     run is worse than no list.
    static func listified(_ text: String) -> String {
        if text.contains("\n") { return text }    // model output already formatted
        if text.hasPrefix("1. ") { return text }  // single-line list markup
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
                // Whole-run bail: any suspect item means the "enumeration" may
                // be prose that happens to start with ordinals — corrupting it
                // is worse than missing it.
                guard items.allSatisfy(Self.parsesCleanly) else { return text }
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

    /// An item body is trustworthy iff its first word was NOT capitalized in
    /// the original text (a capital after the marker means the "ordinal" was
    /// part of a name — "First Street", "Second Avenue" — or the item didn't
    /// start a clause), with the sentence-initial pronoun "I" as the one
    /// legitimate capital; and the body doesn't end in a known abbreviation,
    /// which means the naive sentence splitter cut an item in half ("ask Dr."
    /// + "Brown about the venue.").
    private static func parsesCleanly(_ body: String) -> Bool {
        guard let first = body.first else { return false }
        if first.isUppercase {
            // Allow exactly the pronoun "I" ("I need coffee", "I'm ready").
            let word = body.prefix(while: { !$0.isWhitespace })
            guard word == "I" || word.hasPrefix("I'") else { return false }
        } else if !first.isLowercase {
            return false   // digits/symbols: not a clause start we can vouch for
        }
        // "ask Dr." / "meet at 5 p.m. e.g." — a trailing abbreviation means the
        // sentence split (and thus the item boundary) is wrong.
        let abbreviations: Set<String> = [
            "dr", "mr", "mrs", "ms", "st", "e.g", "i.e", "etc", "inc", "vs",
        ]
        if let lastWord = body.split(whereSeparator: { $0.isWhitespace }).last {
            var token = Substring(lastWord)
            if token.hasSuffix(".") { token = token.dropLast() }
            if abbreviations.contains(token.lowercased()) { return false }
        }
        return true
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
    /// A marker followed by a known idiom continuation ("first of all",
    /// "second thoughts") is NOT an enumeration marker — the sentence is
    /// prose and must never be half-stripped.
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
            guard !item.isEmpty, !startsWithIdiomContinuation(item, after: marker) else {
                return nil
            }
            return item
        }
        return nil
    }

    /// True when the word(s) after an ordinal make it an idiom, not a list
    /// marker: "first of all", "first off", "second thoughts", "third party" …
    /// Small and lowercase-only on purpose — capitalized continuations
    /// ("First Street") are already rejected by `parsesCleanly`.
    private static func startsWithIdiomContinuation(
        _ body: String, after marker: String
    ) -> Bool {
        let continuations: [String: [String]] = [
            "first": ["of all", "off", "and foremost", "things first"],
            "second": ["thoughts", "thought", "nature", "hand", "guess", "guessing"],
            "third": ["party", "parties"],
        ]
        guard let idioms = continuations[marker] else { return false }
        let head = body.lowercased()
        return idioms.contains { idiom in
            head.hasPrefix(idiom)
                && (head.count == idiom.count
                    || !head[head.index(head.startIndex, offsetBy: idiom.count)].isLetter)
        }
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
