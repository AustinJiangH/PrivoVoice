// Opt-in smoke test that runs the REAL formatter model (Qwen3-1.7B-4bit)
// end-to-end (MLX load, chat template with thinking disabled, few-shot turns,
// generation + sanity guards). Skipped unless BOTH hold:
//   • env PRIVOVOICE_FORMATTER_SMOKE=1
//   • the model is installed at the default FormatterStore root
// so plain `swift test` / CI never load MLX or touch the network. Run with:
//   PRIVOVOICE_FORMATTER_SMOKE=1 swift test --filter FormatterSmoke
// Output quality is judged by a human from the printed input→output pairs —
// the assertions stay deliberately loose (non-empty, guard-clean, no leaked
// <think> markup).

import XCTest
import Foundation
import MLX
@testable import PrivoVoiceKit

final class FormatterSmokeTests: XCTestCase {
    /// The installed model directory, or an `XCTSkip` unless the smoke env is
    /// set AND the model is installed (shared gate for every test here).
    private func requireSmokeModel() async throws -> URL {
        guard ProcessInfo.processInfo.environment["PRIVOVOICE_FORMATTER_SMOKE"] == "1" else {
            throw XCTSkip("Set PRIVOVOICE_FORMATTER_SMOKE=1 to run the real-model smoke test.")
        }
        let (installed, directory) = await MainActor.run {
            (FormatterStore.shared.isInstalled, FormatterStore.shared.installDirectory)
        }
        guard installed else {
            throw XCTSkip("Formatter model not installed at \(directory.path).")
        }
        return directory
    }

    func testRealModelCleansTranscripts() async throws {
        let directory = try await requireSmokeModel()

        // Parakeet emits punctuated, capitalized transcripts — the suite leads
        // with those (the old fine-tune returned them verbatim, which is why
        // it was replaced); raw-lowercase cleanup is kept as a regression case.
        let inputs = [
            // Real failing dictation: filler + enumeration + cross-sentence
            // self-correction (Wednesday → Tuesday must be applied).
            "Let's see if this works. First we're gonna try if it can detect the "
                + "order list. Secondly let's see if we can make a plan on Wednesday. "
                + "No actually it's Tuesday. And uh third let's execute the plan.",
            // Punctuated self-correction (keep only Tuesday) + fillers.
            "So um I think we should uh probably meet on Monday. No wait, Tuesday "
                + "works better.",
            // Regression: raw lowercase disfluencies (fillers + "the the").
            "um so uh i think we should uh probably start with the the backend first",
            // Already-clean sentence: must come back essentially unchanged.
            "The quarterly report is ready for review, and I would appreciate "
                + "your feedback by Friday.",
            // A question: must be passed through, never answered.
            "What time is the meeting tomorrow?",
            // Longer ramble with fillers mid-sentence.
            "Okay so um basically what I wanted to say is that the uh the migration "
                + "went fine over the weekend. We moved um I think it was around forty "
                + "services to the new cluster and uh only two of them had issues. The "
                + "uh the logging one and um the billing service which uh we rolled "
                + "back for now.",
            // Real dictation #2: enumeration in the MIDDLE of a longer
            // dictation, with prose before AND after — the list must render
            // and the surrounding sentences must stay in place.
            "Hello, let's test out this new formatter. Let's test this out and see "
                + "if it works. Okay, I want to see if we can deal with bullet points "
                + "right now. First, let's try switching to a different card. Second, "
                + "let's turn on the settings. Third, we should have a live audio and "
                + "see if it really works. All right, that doesn't seem to work. "
                + "Let's try that again. Okay, let's do that on Tuesday.",
        ]

        let formatter = TranscriptFormatter(directory: directory)

        // Phase 1: every capability enabled — each case demonstrates one.
        for (index, input) in inputs.enumerated() {
            try await run(formatter, input: input, options: FormatterOptions(),
                          tag: "SMOKE[\(index)] all-on \(index == 0 ? "cold" : "warm")")
        }

        // Acceptance: the real dictation must come back as a literal numbered
        // list (newline-separated "1. " lines) with the correction applied.
        let listOut = try await formatter.format(inputs[0], options: FormatterOptions())
        XCTAssertTrue(listOut.contains("\n1. "), "expected literal numbered list, got: \(listOut)")
        XCTAssertTrue(listOut.contains("\n2. "), "expected literal numbered list, got: \(listOut)")
        XCTAssertTrue(listOut.contains("Tuesday"), "correction not applied: \(listOut)")
        XCTAssertFalse(listOut.contains("Wednesday"), "correction not applied: \(listOut)")

        // Acceptance #2: enumeration in the MIDDLE of a longer dictation —
        // numbered lines AND the surrounding prose kept in place.
        let midOut = try await formatter.format(inputs[6], options: FormatterOptions())
        XCTAssertTrue(midOut.hasPrefix("Hello"), "leading prose lost: \(midOut)")
        for line in ["\n1. ", "\n2. ", "\n3. "] {
            XCTAssertTrue(midOut.contains(line), "expected literal numbered list, got: \(midOut)")
        }
        XCTAssertTrue(midOut.contains("Tuesday"), "trailing prose lost: \(midOut)")
        XCTAssertFalse(midOut.hasSuffix("really works."), "prose after list lost: \(midOut)")

        // Phase 2: modulation — Qwen3 honors the DISABLED counter-clauses.
        // Fillers case with filler removal OFF (should keep the ums):
        try await run(formatter, input: inputs[2],
                      options: FormatterOptions(removesFillers: false),
                      tag: "SMOKE[mod] fillers-OFF")
        // Correction case with corrections OFF (should keep the chain):
        try await run(formatter, input: inputs[1],
                      options: FormatterOptions(appliesCorrections: false),
                      tag: "SMOKE[mod] corrections-OFF")
        // Enumeration case with lists OFF (should stay prose):
        try await run(formatter, input: inputs[0],
                      options: FormatterOptions(formatsLists: false),
                      tag: "SMOKE[mod] lists-OFF")
    }

    /// After a prewarm, a format must actually HIT the prefix cache — and the
    /// anchor must be the real prompt's literal token prefix. reused == the
    /// full preamble length proves both (reuse requires byte equality); a
    /// silent always-fallback regression fails here instead of just being slow.
    func testWarmFormatReusesTheAnchoredPreamble() async throws {
        let directory = try await requireSmokeModel()
        let formatter = TranscriptFormatter(directory: directory)
        try await formatter.prewarm(options: FormatterOptions())
        let preamble = await formatter.preambleTokensForTesting()
        XCTAssertFalse(preamble.isEmpty, "prewarm must anchor the preamble")

        let (output, stats) = try await formatter.generateWithStats(
            "So um the report should go out on Friday.", options: FormatterOptions())
        print("SMOKE[cache-hit] reused=\(stats.reusedTokenCount)/\(stats.promptTokenCount)")
        XCTAssertFalse(output.isEmpty)
        XCTAssertGreaterThan(stats.reusedTokenCount, 0,
                             "a warm format must be served from the prefix cache")
        XCTAssertEqual(stats.reusedTokenCount, preamble.count,
                       "the real prompt's tokens must start with the built preamble")
    }

    /// A per-request prefix-seam mismatch must fall back to a full prefill for
    /// THAT request only: same output, and the (input-independent) anchor
    /// survives instead of forcing a re-anchor on the next request.
    func testPrefixMismatchFallbackMatchesCachedOutput() async throws {
        let directory = try await requireSmokeModel()
        let formatter = TranscriptFormatter(directory: directory)
        let input = "Um so I think we should probably meet on Monday. No wait, "
            + "Tuesday works better."
        try await formatter.prewarm(options: FormatterOptions())
        let (cached, cachedStats) = try await formatter.generateWithStats(
            input, options: FormatterOptions())
        XCTAssertGreaterThan(cachedStats.reusedTokenCount, 0)

        await formatter.corruptAnchorForTesting()
        let (fallback, fallbackStats) = try await formatter.generateWithStats(
            input, options: FormatterOptions())
        print("SMOKE[fallback] reused=\(fallbackStats.reusedTokenCount) "
              + "prefill=\(Int(fallbackStats.prefillTime * 1000))ms")
        XCTAssertEqual(fallbackStats.reusedTokenCount, 0,
                       "a corrupted prefix must not be reused")
        // Temperature 0: the full-prefill path must reproduce the cached
        // path's bytes exactly — the cache is purely a latency optimization.
        XCTAssertEqual(fallback, cached)
        // And the anchor was NOT reset by the mismatch (C1): the next request
        // must not pay a re-anchor.
        let survivingAnchor = await formatter.preambleTokensForTesting()
        XCTAssertFalse(survivingAnchor.isEmpty, "seam mismatch must keep the anchor")
    }

    /// A format cancelled mid-decode must not poison the cache: the next
    /// (uncancelled) format returns the normal result.
    func testCancelledFormatThenNormalFormatSucceeds() async throws {
        let directory = try await requireSmokeModel()
        let formatter = TranscriptFormatter(directory: directory)
        let input = "Okay so um basically the migration went fine over the weekend "
            + "and uh only two of the forty services had issues, the logging one "
            + "and um the billing service which we rolled back for now."
        try await formatter.prewarm(options: FormatterOptions())
        let reference = try await formatter.format(input, options: FormatterOptions())

        let cancelled = Task { try await formatter.format(input, options: FormatterOptions()) }
        try await Task.sleep(nanoseconds: 200_000_000)   // let it get into the decode
        cancelled.cancel()
        _ = try? await cancelled.value   // CancellationError (or a partial that was discarded)

        let after = try await formatter.format(input, options: FormatterOptions())
        XCTAssertEqual(after, reference,
                       "a cancelled format must not corrupt the next one")
    }

    /// Prewarming for one option set then formatting with another must
    /// re-anchor transparently — and still hit the fresh anchor in the same
    /// request.
    func testPrewarmOptionsMismatchReanchorsOnFormat() async throws {
        let directory = try await requireSmokeModel()
        let formatter = TranscriptFormatter(directory: directory)
        try await formatter.prewarm(options: FormatterOptions(formatsLists: false))
        let (output, stats) = try await formatter.generateWithStats(
            "Um so send the invoice on Friday please.", options: FormatterOptions())
        print("SMOKE[re-anchor] reused=\(stats.reusedTokenCount)/\(stats.promptTokenCount)")
        XCTAssertFalse(output.isEmpty)
        XCTAssertGreaterThan(stats.reusedTokenCount, 0,
                             "the options change must rebuild the anchor, then reuse it")
    }

    /// `unloadFormatter` must actually hand the ~1 GB of weights back — both
    /// the live arrays (container drop) and MLX's buffer reuse cache
    /// (`GPU.clearCache()`).
    func testUnloadFreesFormatterMemory() async throws {
        let directory = try await requireSmokeModel()

        let engine = InProcessDictationEngine()
        await engine.warmFormatter(modelPath: directory.path, options: FormatterOptions())
        let before = GPU.snapshot()
        XCTAssertGreaterThan(before.activeMemory, 500 << 20,
                             "the model should be resident after a warm-up")
        await engine.unloadFormatter()
        let after = GPU.snapshot()
        print("SMOKE[unload] MLX active \(before.activeMemory >> 20) MB -> "
              + "\(after.activeMemory >> 20) MB, cache \(after.cacheMemory >> 20) MB")
        XCTAssertLessThan(after.activeMemory, 200 << 20,
                          "unload must release the model weights")
        XCTAssertLessThan(after.cacheMemory, 200 << 20,
                          "unload must clear MLX's buffer cache")
    }

    private func run(
        _ formatter: TranscriptFormatter, input: String,
        options: FormatterOptions, tag: String
    ) async throws {
        let start = Date()
        let raw = try await formatter.generate(input, options: options)
        let elapsed = Date().timeIntervalSince(start)
        let cleaned = TranscriptFormatter.accepted(
            output: TranscriptFormatter.unwrapped(raw, input: input), input: input)
        let output = options.formatsLists ? TranscriptFormatter.listified(cleaned) : cleaned
        print("\(tag) " + String(format: "%.2f", elapsed) + "s")
        print("\(tag)  IN : \(input)")
        print("\(tag)  RAW: \(raw)")
        print("\(tag)  OUT: \(output)")
        XCTAssertFalse(output.isEmpty, "format() must never return empty")
        XCTAssertFalse(output.contains("<think>"), "thinking must be disabled/stripped")
        // The public API path must agree (same guards, same options).
        let viaFormat = try await formatter.format(input, options: options)
        XCTAssertEqual(viaFormat, output)
    }
}
