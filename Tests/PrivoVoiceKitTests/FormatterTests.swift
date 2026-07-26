// Coverage for the optional final-transcript formatter: the pure sanity-guard
// logic, the persisted setting's default, FormatterStore installed-ness
// detection, and the DictationController polish path (success / failure /
// timeout / disabled) with a mock engine — no model download anywhere.

import XCTest
import Foundation
import VoixfulEngine
@testable import PrivoVoiceKit

// MARK: - Sanity guards (pure)

final class FormatterSanityGuardTests: XCTestCase {
    func testEmptyOutputFallsBackToInput() {
        XCTAssertEqual(TranscriptFormatter.accepted(output: "", input: "hello there"), "hello there")
        XCTAssertEqual(TranscriptFormatter.accepted(output: "  \n ", input: "hello there"), "hello there")
    }

    func testSuspiciouslyShortOutputFallsBackForLongInput() {
        // > 80-char input with an output under a quarter of its length smells
        // like a summary/answer, not a cleanup.
        let input = String(repeating: "the quick brown fox ", count: 6)   // 120 chars
        XCTAssertEqual(TranscriptFormatter.accepted(output: "A fox runs.", input: input), input)
    }

    func testShortInputMayShrinkFreely() {
        // The 25% guard only arms above 80 chars — "um, hello" → "Hello." is fine.
        XCTAssertEqual(TranscriptFormatter.accepted(output: "Hi.", input: "um, hello there friend"), "Hi.")
    }

    func testHeavyDisfluencyCleanupPassesShortGuard() {
        // Removing fillers + a correction chain legitimately shrinks a long
        // input to ~36% — well above the 25% floor, so it must be accepted
        // (mirrors the real-model smoke case; guards stay as-is on purpose).
        let input = "okay so um the meeting is on uh monday no wait um actually tuesday no "
            + "hold on let me check um yeah wednesday at uh ten am"
        let cleaned = "Okay so the meeting is on Wednesday at 10 am"
        XCTAssertEqual(TranscriptFormatter.accepted(output: cleaned, input: input), cleaned)
    }

    func testRunawayLongOutputFallsBackToInput() {
        let input = "add eggs and milk"
        let runaway = String(repeating: "list item ", count: 40)
        XCTAssertEqual(TranscriptFormatter.accepted(output: runaway, input: input), input)
    }

    func testGoodOutputIsTrimmedAndAccepted() {
        XCTAssertEqual(
            TranscriptFormatter.accepted(output: "  First: eggs. Then: milk.\n", input: "first eggs then milk"),
            "First: eggs. Then: milk.")
    }

    // Wrapper stripping: <output> tags (old fine-tune), <think> blocks
    // (Qwen3 — defense in depth, thinking is disabled at the template level),
    // and quotes the speaker didn't dictate.
    func testUnwrappedStripsOutputTags() {
        XCTAssertEqual(
            TranscriptFormatter.unwrapped("<output>Hi there.</output>", input: "hi there"),
            "Hi there.")
    }

    func testUnwrappedStripsLeadingThinkBlock() {
        XCTAssertEqual(
            TranscriptFormatter.unwrapped(
                "<think>\nThe user wants cleanup.\n</think>\n\nHi there.", input: "hi there"),
            "Hi there.")
    }

    func testUnwrappedEmptiesUnterminatedThinkBlock() {
        // All reasoning, no cleanup: unwrapped returns "" so accepted falls
        // back to the original input.
        let raw = "<think>\nStill thinking about the transcript"
        XCTAssertEqual(TranscriptFormatter.unwrapped(raw, input: "hi there"), "")
        XCTAssertEqual(
            TranscriptFormatter.accepted(
                output: TranscriptFormatter.unwrapped(raw, input: "hi there"),
                input: "hi there"),
            "hi there")
    }

    func testUnwrappedStripsThinkThenQuotes() {
        XCTAssertEqual(
            TranscriptFormatter.unwrapped(
                "<think></think> \"Buy milk.\"", input: "buy milk"),
            "Buy milk.")
    }

    func testUnwrappedStripsAddedQuotes() {
        XCTAssertEqual(
            TranscriptFormatter.unwrapped("\"Buy milk.\"", input: "buy milk"),
            "Buy milk.")
    }

    func testUnwrappedKeepsSpokenQuotes() {
        // If the transcript itself is a quotation, the model's quotes stay.
        XCTAssertEqual(
            TranscriptFormatter.unwrapped("\"Buy milk.\"", input: "\"buy milk\""),
            "\"Buy milk.\"")
    }

    func testUnwrappedKeepsQuotesWhenInputContainsAnyQuote() {
        // Quoted spans hidden behind edge fillers: the output's leading and
        // trailing quotes belong to two DIFFERENT spans — stripping the pair
        // would unbalance it. Any quote in the input disables the strip.
        XCTAssertEqual(
            TranscriptFormatter.unwrapped(
                "\"Yes,\" she said, \"no.\"",
                input: "um \"yes\" she said \"no\" um"),
            "\"Yes,\" she said, \"no.\"")
    }

    func testUnwrappedLeavesPlainTextAlone() {
        XCTAssertEqual(
            TranscriptFormatter.unwrapped("Just a sentence.", input: "just a sentence"),
            "Just a sentence.")
    }

    func testUnwrappedKeepsListNewlinesButStripsTrailingSpaces() {
        // The model emits markdown-style "  \n" hard breaks in list output;
        // trailing whitespace goes, internal newlines stay untouched.
        let raw = "Intro sentence.  \n1. First item.  \n2. Second item.\n"
        XCTAssertEqual(
            TranscriptFormatter.unwrapped(raw, input: "intro sentence first item second item"),
            "Intro sentence.\n1. First item.\n2. Second item.")
    }

    func testAcceptedKeepsMultiLineListOutput() {
        let input = "Let's plan. First do the budget. Second do the timeline. "
            + "And third do the hiring."
        let list = "Let's plan.\n1. Do the budget.\n2. Do the timeline.\n3. Do the hiring."
        XCTAssertEqual(TranscriptFormatter.accepted(output: list, input: input), list)
    }
}

// MARK: - Deterministic list rendering (pure)

final class FormatterListifyTests: XCTestCase {
    func testMidTranscriptEnumerationBecomesListWithSurroundingProse() {
        let prose = "Hello there. Here is the plan for today. "
            + "First, let's try switching to a different card. "
            + "Second, let's turn on the settings. "
            + "Third, we should have a live audio. "
            + "All right, that didn't work. Let's do that on Tuesday."
        XCTAssertEqual(
            TranscriptFormatter.listified(prose),
            "Hello there. Here is the plan for today.\n"
                + "1. Let's try switching to a different card.\n"
                + "2. Let's turn on the settings.\n"
                + "3. We should have a live audio.\n"
                + "All right, that didn't work. Let's do that on Tuesday.")
    }

    func testEnumerationAtEndBecomesList() {
        XCTAssertEqual(
            TranscriptFormatter.listified(
                "Here we go. First we tag the build. Secondly we push it. "
                    + "And third we email the testers."),
            "Here we go.\n1. We tag the build.\n2. We push it.\n3. We email the testers.")
    }

    func testFourthAndFinallyContinueTheList() {
        XCTAssertEqual(
            TranscriptFormatter.listified(
                "First pack. Second drive. Third arrive. Fourth unpack. Finally rest."),
            "1. Pack.\n2. Drive.\n3. Arrive.\n4. Unpack.\n5. Rest.")
    }

    func testLoneFirstDoesNotArm() {
        // "first" without a following "second" sentence stays prose.
        let s = "First impressions matter. We should polish the onboarding."
        XCTAssertEqual(TranscriptFormatter.listified(s), s)
    }

    func testFirstAtSentenceEndDoesNotArm() {
        let s = "I think we should start with the backend first."
        XCTAssertEqual(TranscriptFormatter.listified(s), s)
    }

    func testAlreadyFormattedListIsUntouched() {
        let s = "Intro.\n1. One thing.\n2. Another thing."
        XCTAssertEqual(TranscriptFormatter.listified(s), s)
    }

    func testPlainTextAndQuestionsAreUntouched() {
        XCTAssertEqual(
            TranscriptFormatter.listified("What time is the meeting tomorrow?"),
            "What time is the meeting tomorrow?")
        let clean = "The quarterly report is ready for review, and I would "
            + "appreciate your feedback by Friday."
        XCTAssertEqual(TranscriptFormatter.listified(clean), clean)
    }

    func testFirstlyDoesNotFalselyMatchFirstBoundary() {
        XCTAssertEqual(
            TranscriptFormatter.listified("Firstly clean the desk. Secondly file the mail."),
            "1. Clean the desk.\n2. File the mail.")
    }

    // MARK: parse-clean-or-bail — every corruption becomes a benign miss

    func testOrdinalStreetNamesStayProse() {
        // "First"/"Second" as parts of proper names: the capitalized bodies
        // fail the clean-parse rule, so the whole input is untouched.
        let s = "First Street is closed. Second Avenue is jammed."
        XCTAssertEqual(TranscriptFormatter.listified(s), s)
    }

    func testFirstOfAllIdiomStaysProse() {
        // "First of all" is an idiom, not a marker — and with no armed first
        // item, the lone "Second, …" sentence can't start a list either.
        // (A real enumeration opened with a multi-word marker bails to prose
        // instead of getting half-stripped — an acceptable miss.)
        let s = "First of all, thanks everyone. Second, let's review the budget."
        XCTAssertEqual(TranscriptFormatter.listified(s), s)
    }

    func testSecondThoughtsIdiomStaysProse() {
        let s = "First we lock the date. Second thoughts keep creeping in."
        XCTAssertEqual(TranscriptFormatter.listified(s), s)
    }

    func testAbbreviationSplitItemBailsTheWholeRun() {
        // The naive sentence splitter cuts "Dr. Brown" in half; the item body
        // ending "Dr." reveals the bad split, and the WHOLE run bails —
        // item 1 must not be listified while item 2 is mangled.
        let s = "First, call the vendor. Second, ask Dr. Brown about the venue."
        XCTAssertEqual(TranscriptFormatter.listified(s), s)
    }

    func testCapitalizedLaterItemBailsTheWholeRun() {
        // Items 1–2 parse cleanly but item 3 is a proper name — partial
        // stripping is the corruption, so everything stays prose.
        let s = "First we pack. Second we drive. Third Street is where we park."
        XCTAssertEqual(TranscriptFormatter.listified(s), s)
    }

    func testMultilineModelOutputIsNeverFlattened() {
        // The model already chose a layout (dash bullets here) — the prose
        // pass must not run at all on multi-line text.
        let s = "Here's the plan.\n- tag the build\n- push it to staging"
        XCTAssertEqual(TranscriptFormatter.listified(s), s)
    }

    func testSingleLineLeadingListMarkupIsUntouched() {
        XCTAssertEqual(TranscriptFormatter.listified("1. Only item"), "1. Only item")
    }

    func testVersionNumberProseDoesNotSuppressRealEnumeration() {
        // The old guard was `contains("1. ")`, which "version 1. " tripped —
        // the anchored check lets the genuine enumeration format.
        XCTAssertEqual(
            TranscriptFormatter.listified(
                "We shipped version 1. First we tag the build. Second we push it."),
            "We shipped version 1.\n1. We tag the build.\n2. We push it.")
    }

    func testSentenceInitialPronounIParsesCleanly() {
        // "I" is the one legitimate capital after a marker.
        XCTAssertEqual(
            TranscriptFormatter.listified("First I need coffee. Second I'm booking the room."),
            "1. I need coffee.\n2. I'm booking the room.")
    }

    func testItemFinalTitleAbbreviationBailsTheWholeRun() {
        // Review case: the splitter cuts "Prof. Brown" in half, stranding
        // "Brown about it." — the whole input must come back untouched.
        let s = "First we tag the build. Second we ping Prof. Brown about it."
        XCTAssertEqual(TranscriptFormatter.listified(s), s)
    }

    func testExpandedAbbreviationSetBailsTheWholeRun() {
        // Sampling of the widened whitelist ("Sgt.", "Ave.", "no.", …): every
        // item-final abbreviation is a bad split, so everything stays prose.
        for s in [
            "First call the office. Second brief Sgt. Miller on the change.",
            "First we lock up. Second we drive down Fifth Ave. Then we park.",
            "First check the list. Second file it under no. 5 in the binder.",
            "First we email Rev. Green. Second we book the hall.",
        ] {
            XCTAssertEqual(TranscriptFormatter.listified(s), s)
        }
    }

    func testUnknownCapitalizedAbbreviationTripsStructuralBackstop() {
        // "Msgr." is NOT in the whitelist — the structural backstop (short
        // capitalized ender + capitalized next sentence) must still bail.
        let s = "First we tag the build. Second we ping Msgr. Kelly about it."
        XCTAssertEqual(TranscriptFormatter.listified(s), s)
    }

    func testLowercaseItemEnderKeepsProseAfterListRendering() {
        // The backstop must NOT bail genuine prose after a list: "audio." is a
        // lowercase ender, so "All right, …" is a real continuation.
        XCTAssertEqual(
            TranscriptFormatter.listified(
                "First we set the card. Second we test the audio. "
                    + "All right, that didn't work."),
            "1. We set the card.\n2. We test the audio.\nAll right, that didn't work.")
    }

    // MARK: comma after the ordinal disables the idiom veto

    func testCommaAfterOrdinalSkipsIdiomCheck() {
        // "second hand" is an idiom — but "Second, hand them out" is not:
        // the comma (consumed at strip time) marks a real enumeration.
        XCTAssertEqual(
            TranscriptFormatter.listified(
                "First, collect the badges. Second, hand them out at the door."),
            "1. Collect the badges.\n2. Hand them out at the door.")
    }

    func testCommaGuessAndOffSiteEnumerationsListify() {
        XCTAssertEqual(
            TranscriptFormatter.listified(
                "First, off-site backups need testing. "
                    + "Second, guess the password reset flow."),
            "1. Off-site backups need testing.\n2. Guess the password reset flow.")
    }

    func testIdiomWithoutCommaStillStaysProse() {
        // No comma → the idiom veto still applies ("second hand me" reads as
        // "second-hand"); a benign miss, never a half-stripped run.
        let s = "First we lock the date. Second hand me the badge list."
        XCTAssertEqual(TranscriptFormatter.listified(s), s)
    }

    // MARK: rendering details

    func testCamelCaseFirstWordIsNotMangled() {
        // "iPhone" must not become "IPhone" — only capitalize when the first
        // word has no uppercase of its own.
        XCTAssertEqual(
            TranscriptFormatter.listified(
                "First iPhone setup gets done. Second we sync the contacts."),
            "1. iPhone setup gets done.\n2. We sync the contacts.")
    }

    func testNotArmedInputIsReturnedByteIdentical() {
        // When no list is built the ORIGINAL string comes back byte-identical
        // — the old sentence-split+rejoin collapsed runs of spaces.
        let s = "We shipped it.  Double  spaces must survive the pass."
        XCTAssertEqual(TranscriptFormatter.listified(s), s)
    }
}

// MARK: - Settings

final class FormatterSettingTests: XCTestCase {
    @MainActor
    func testFormatFinalTranscriptDefaultsOffAndPersists() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "fmt-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let settings = AppSettings(storeURL: url)
        XCTAssertFalse(settings.formatFinalTranscript, "must default OFF")

        settings.formatFinalTranscript = true
        settings.saveNow()
        let reloaded = AppSettings(storeURL: url)
        XCTAssertTrue(reloaded.formatFinalTranscript)
    }

    @MainActor
    func testCapabilityTogglesDefaultOnAndPersist() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "fmt-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let settings = AppSettings(storeURL: url)
        XCTAssertTrue(settings.formatterRemovesFillers, "must default ON")
        XCTAssertTrue(settings.formatterFormatsLists, "must default ON")
        XCTAssertTrue(settings.formatterAppliesCorrections, "must default ON")

        settings.formatterRemovesFillers = false
        settings.formatterAppliesCorrections = false
        settings.saveNow()
        let reloaded = AppSettings(storeURL: url)
        XCTAssertFalse(reloaded.formatterRemovesFillers)
        XCTAssertTrue(reloaded.formatterFormatsLists)
        XCTAssertFalse(reloaded.formatterAppliesCorrections)
    }
}

// MARK: - Prompt assembly (pure)

final class FormatterPromptAssemblyTests: XCTestCase {
    private let base = "You are a transcript cleanup tool."
    private let fillers = "Remove disfluencies"
    private let corrections = "rewrite the sentence as if the speaker had said"
    private let lists = "render the enumeration as a numbered list"
    private let constraints = "Output only the cleaned transcript."

    func testAllOptionsOnIncludesEveryClause() {
        let p = TranscriptFormatter.systemPrompt(for: FormatterOptions())
        XCTAssertTrue(p.hasPrefix(base))
        XCTAssertTrue(p.contains(fillers))
        XCTAssertTrue(p.contains(corrections))
        XCTAssertTrue(p.contains(lists))
        XCTAssertTrue(p.hasSuffix(constraints))
    }

    func testAllOptionsOffIsBasePlusConstraintsOnly() {
        let p = TranscriptFormatter.systemPrompt(for: FormatterOptions(
            removesFillers: false, formatsLists: false, appliesCorrections: false))
        XCTAssertTrue(p.hasPrefix(base))
        XCTAssertFalse(p.contains(fillers))
        XCTAssertFalse(p.contains(corrections))
        XCTAssertFalse(p.contains(lists))
        XCTAssertTrue(p.hasSuffix(constraints))
    }

    func testEachToggleControlsExactlyItsClause() {
        let onlyFillers = TranscriptFormatter.systemPrompt(for: FormatterOptions(
            removesFillers: true, formatsLists: false, appliesCorrections: false))
        XCTAssertTrue(onlyFillers.contains(fillers))
        XCTAssertFalse(onlyFillers.contains(corrections))
        XCTAssertFalse(onlyFillers.contains(lists))

        let onlyLists = TranscriptFormatter.systemPrompt(for: FormatterOptions(
            removesFillers: false, formatsLists: true, appliesCorrections: false))
        XCTAssertFalse(onlyLists.contains(fillers))
        XCTAssertFalse(onlyLists.contains(corrections))
        XCTAssertTrue(onlyLists.contains(lists))

        let onlyCorrections = TranscriptFormatter.systemPrompt(for: FormatterOptions(
            removesFillers: false, formatsLists: false, appliesCorrections: true))
        XCTAssertFalse(onlyCorrections.contains(fillers))
        XCTAssertTrue(onlyCorrections.contains(corrections))
        XCTAssertFalse(onlyCorrections.contains(lists))
    }

    func testFormatterOptionsDefaultsAllTrue() {
        let options = FormatterOptions()
        XCTAssertTrue(options.removesFillers)
        XCTAssertTrue(options.formatsLists)
        XCTAssertTrue(options.appliesCorrections)
    }
}

// MARK: - Few-shot example composition (pure)

final class FormatterFewShotTests: XCTestCase {
    // Example order: [0] clean passthrough, [1] correction, [2] trip list,
    // [3] release-steps list (sentence-per-item, mirrors real dictations).
    func testFourExamplesWithFixedInputs() {
        let examples = TranscriptFormatter.fewShotExamples(for: FormatterOptions())
        XCTAssertEqual(examples.count, 4)
        // Inputs never vary with the toggles — only the expected outputs do.
        let off = TranscriptFormatter.fewShotExamples(for: FormatterOptions(
            removesFillers: false, formatsLists: false, appliesCorrections: false))
        XCTAssertEqual(examples.map(\.input), off.map(\.input))
        XCTAssertTrue(examples[1].input.contains("No wait, Friday is better"))
        XCTAssertTrue(examples[2].input.contains("Secondly"))
        XCTAssertTrue(examples[3].input.contains("And um third"))
    }

    func testCleanPassthroughExampleIsIdentityForEveryToggle() {
        for options in [
            FormatterOptions(),
            FormatterOptions(removesFillers: false, formatsLists: false,
                             appliesCorrections: false),
        ] {
            let example = TranscriptFormatter.fewShotExamples(for: options)[0]
            XCTAssertEqual(example.input, example.output)
        }
    }

    func testAllOnOutputsDemonstrateEveryCapability() {
        let examples = TranscriptFormatter.fewShotExamples(for: FormatterOptions())
        // Correction example: filler gone, Thursday→Friday applied.
        XCTAssertEqual(
            examples[1].output,
            "So the invoice should go out on Friday. "
                + "And she can review it after the weekend.")
        // List examples: literal numbered lines with real newlines,
        // corrections applied, fillers gone.
        XCTAssertTrue(examples[2].output.contains("\n1. We should book the hotel.\n"))
        XCTAssertTrue(examples[2].output.contains("\n2. We need to rent a car on Sunday.\n"))
        XCTAssertTrue(examples[2].output.hasSuffix("3. Let's pack the gear."))
        XCTAssertFalse(examples[2].output.contains("um"))
        XCTAssertFalse(examples[2].output.contains("Saturday"))
        XCTAssertTrue(examples[3].output.contains(
            "Okay, let me walk through the release steps.\n1. Let's tag the build.\n"))
        XCTAssertTrue(examples[3].output.contains("2. Let's push it to staging on Friday.\n"))
        XCTAssertFalse(examples[3].output.contains("Thursday"))
    }

    func testDisabledTogglesAreDemonstratedNotJustDescribed() {
        let fillersOff = TranscriptFormatter.fewShotExamples(for: FormatterOptions(
            removesFillers: false))
        XCTAssertTrue(fillersOff[1].output.hasPrefix("Um, so"))
        XCTAssertTrue(fillersOff[2].output.contains("um, book the hotel"))

        let correctionsOff = TranscriptFormatter.fewShotExamples(for: FormatterOptions(
            appliesCorrections: false))
        XCTAssertTrue(correctionsOff[1].output.contains("Thursday. No wait, Friday is better."))
        XCTAssertTrue(correctionsOff[2].output.contains("Saturday. No wait, it's Sunday"))

        let listsOff = TranscriptFormatter.fewShotExamples(for: FormatterOptions(
            formatsLists: false))
        XCTAssertFalse(listsOff[2].output.contains("1."))
        XCTAssertFalse(listsOff[3].output.contains("\n"))
        XCTAssertTrue(listsOff[2].output.contains("First we should book the hotel."))
    }
}

// MARK: - FormatterStore installed-ness (filesystem only, no network)

final class FormatterStoreTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "fmt-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Write a directory that passes `looksInstalled` (config + weights +
    /// tokenizer) and return it.
    @discardableResult
    private func makeInstalled(at root: URL) throws -> URL {
        let dir = root.appending(path: FormatterCatalog.installSlug, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appending(path: "config.json"))
        try Data("w".utf8).write(to: dir.appending(path: "model.safetensors"))
        try Data("{}".utf8).write(to: dir.appending(path: "tokenizer.json"))
        return dir
    }

    /// Poll until `path` no longer exists (off-main-actor deletes).
    @MainActor
    private func waitGone(_ path: String, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while FileManager.default.fileExists(atPath: path), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    func testFreshStoreIsNotInstalled() throws {
        let store = FormatterStore(rootDirectory: try makeRoot())
        XCTAssertEqual(store.phase, .notInstalled)
        XCTAssertFalse(store.isInstalled)
    }

    @MainActor
    func testDetectsInstalledSnapshotOnInit() throws {
        let root = try makeRoot()
        try makeInstalled(at: root)

        let store = FormatterStore(rootDirectory: root)
        XCTAssertEqual(store.phase, .installed)
        XCTAssertTrue(store.isInstalled)
    }

    @MainActor
    func testConfigAloneIsNotInstalled() throws {
        let root = try makeRoot()
        let dir = root.appending(path: FormatterCatalog.installSlug, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appending(path: "config.json"))

        XCTAssertFalse(FormatterStore.looksInstalled(at: dir))
        XCTAssertEqual(FormatterStore(rootDirectory: root).phase, .notInstalled)
    }

    @MainActor
    func testMissingTokenizerIsNotInstalled() throws {
        // A cancelled Hub snapshot returns a PARTIAL directory that can hold
        // config + weights but no tokenizer — it must not count as installed.
        let root = try makeRoot()
        let dir = root.appending(path: FormatterCatalog.installSlug, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appending(path: "config.json"))
        try Data("w".utf8).write(to: dir.appending(path: "model.safetensors"))

        XCTAssertFalse(FormatterStore.looksInstalled(at: dir))
        XCTAssertEqual(FormatterStore(rootDirectory: root).phase, .notInstalled)
    }

    @MainActor
    func testRemoveResetsPhaseAndDeletes() async throws {
        let root = try makeRoot()
        let dir = try makeInstalled(at: root)
        // A crash-orphaned staging dir must be swept by remove() too.
        let orphan = FormatterStore.stagingDirectory(root: root, generation: 3)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

        let store = FormatterStore(rootDirectory: root)
        XCTAssertTrue(store.isInstalled)
        store.remove()
        XCTAssertEqual(store.phase, .notInstalled)
        // The deletes themselves run off the main actor — poll briefly.
        await waitGone(dir.path)
        await waitGone(orphan.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    // MARK: download generations (state machine only — no network)

    @MainActor
    func testStaleDownloadCallbacksAreIgnored() throws {
        let store = FormatterStore(rootDirectory: try makeRoot())
        let gen1 = store.beginDownload()
        XCTAssertEqual(store.phase, .downloading(0))
        let gen2 = store.beginDownload()   // superseding attempt

        // Late hops from the superseded attempt: all no-ops.
        store.downloadDidProgress(0.5, generation: gen1)
        XCTAssertEqual(store.phase, .downloading(0))
        store.downloadDidSucceed(generation: gen1)
        XCTAssertEqual(store.phase, .downloading(0))
        store.downloadDidFail("boom", generation: gen1)
        XCTAssertEqual(store.phase, .downloading(0))

        // The current attempt still drives the phase.
        store.downloadDidProgress(0.25, generation: gen2)
        XCTAssertEqual(store.phase, .downloading(0.25))
        store.downloadDidSucceed(generation: gen2)
        XCTAssertEqual(store.phase, .installed)
    }

    @MainActor
    func testRemoveStalifiesInFlightDownloadCallbacks() throws {
        let store = FormatterStore(rootDirectory: try makeRoot())
        let gen = store.beginDownload()
        store.remove()
        XCTAssertEqual(store.phase, .notInstalled)
        // The cancelled attempt's late hops must not resurrect any state —
        // in particular success must not flip a removed store to .installed.
        store.downloadDidSucceed(generation: gen)
        XCTAssertEqual(store.phase, .notInstalled)
        store.downloadDidFail("cancelled", generation: gen)
        XCTAssertEqual(store.phase, .notInstalled)
        store.downloadDidProgress(0.9, generation: gen)
        XCTAssertEqual(store.phase, .notInstalled)
    }

    @MainActor
    func testFailureOnlyLandsWhileStillDownloading() throws {
        let store = FormatterStore(rootDirectory: try makeRoot())
        let gen = store.beginDownload()
        store.downloadDidFail("network down", generation: gen)
        XCTAssertEqual(store.phase, .failed("network down"))
        // A duplicate late failure hop for the same (now finished) attempt.
        store.downloadDidFail("late duplicate", generation: gen)
        XCTAssertEqual(store.phase, .failed("network down"))
    }

    func testStagingDirectoriesArePerGeneration() {
        let root = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        let a = FormatterStore.stagingDirectory(root: root, generation: 1)
        let b = FormatterStore.stagingDirectory(root: root, generation: 2)
        XCTAssertNotEqual(a.path, b.path)
        XCTAssertTrue(a.lastPathComponent.hasPrefix(FormatterCatalog.installSlug + ".partial"))
    }

    @MainActor
    func testInitSweepsOrphanedStagingButKeepsInstall() async throws {
        let root = try makeRoot()
        let dir = try makeInstalled(at: root)
        // Crash orphans: the old un-numbered layout and a numbered generation.
        let legacy = root.appending(path: FormatterCatalog.installSlug + ".partial",
                                    directoryHint: .isDirectory)
        let numbered = FormatterStore.stagingDirectory(root: root, generation: 7)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: numbered, withIntermediateDirectories: true)

        let store = FormatterStore(rootDirectory: root)
        XCTAssertTrue(store.isInstalled)
        await waitGone(legacy.path)
        await waitGone(numbered.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: numbered.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path),
                      "the install itself must survive the sweep")
    }
}

// MARK: - Controller polish path

/// A `DictationEngine` fake whose `format` behavior is scripted per test.
actor FormatMockEngine: DictationEngine {
    enum FormatBehavior {
        case succeed(String)
        case fail
        case hang            // hangs until the task is cancelled (like the real engines)
    }
    var finalText = "raw transcript"
    var behavior: FormatBehavior = .succeed("Polished transcript.")
    private(set) var formatCalls = 0
    private(set) var cancelCalls = 0
    /// Set when a hanging format observed its task's cancellation — the real
    /// engines' cancellation-responsiveness, mirrored so the controller tests
    /// can assert the polish timeout genuinely cancels the format child.
    private(set) var formatCancelled = false

    func setBehavior(_ b: FormatBehavior) { behavior = b }
    func setFinal(_ t: String) { finalText = t }

    func begin(modelURL: URL, backend: ModelBackend, locale: Locale,
               format: AudioStreamFormat, onPartial: @escaping @Sendable (String) -> Void) async throws {}
    func feed(_ samples: [Float]) {}
    func end() async throws -> String { finalText }
    func cancel() { cancelCalls += 1 }

    private(set) var lastOptions: FormatterOptions?
    private(set) var warmCalls: [String] = []
    private(set) var warmOptions: [FormatterOptions] = []
    private(set) var unloadCalls = 0
    /// Ordered warm/unload COMPLETIONS. "warm" lands only after a deliberate
    /// delay, so an unchained unload could overtake it — the residency-order
    /// test fails without the controller's `residencyTask` serialization.
    private(set) var residencyEvents: [String] = []

    func warmFormatter(modelPath: String, options: FormatterOptions) async {
        warmCalls.append(modelPath)
        warmOptions.append(options)
        try? await Task.sleep(nanoseconds: 20_000_000)
        residencyEvents.append("warm")
    }

    func unloadFormatter() {
        unloadCalls += 1
        residencyEvents.append("unload")
    }

    func format(text: String, modelPath: String, options: FormatterOptions) async throws -> String {
        formatCalls += 1
        lastOptions = options
        switch behavior {
        case .succeed(let t): return t
        case .fail: throw Boom()
        case .hang:
            do {
                try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            } catch {
                formatCancelled = true
                throw error
            }
            return text
        }
    }
    struct Boom: Error {}
}

final class FormatterControllerTests: XCTestCase {

    @MainActor
    private func makeController(
        engine: FormatMockEngine
    ) throws -> (DictationController, AppState, AppSettings) {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "fmt-ctl-\(UUID().uuidString)")
        let settings = AppSettings(storeURL: tmp.appending(path: "settings.json"))
        settings.modelsDirectory = tmp.appending(path: "models")
        let store = ModelStore(settings: settings)
        let spec = ModelCatalog.all[0]
        let asset = store.installURL(for: spec)
        try FileManager.default.createDirectory(at: asset, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: asset.appending(path: "marker"))
        settings.selectedModelID = spec.id
        store.refresh()
        let appState = AppState()
        let controller = DictationController(
            appState: appState, settings: settings, store: store,
            engine: engine, makeCapture: { MockCapture() })
        return (controller, appState, settings)
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () async -> Bool,
                           timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            if Date() > deadline { XCTFail("timed out waiting for condition", file: file, line: line); return }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
    }

    /// Run one start/stop session with formatting enabled and return the
    /// delivered transcript (autoSpacing left ON, matching existing tests).
    @MainActor
    private func runSession(
        _ controller: DictationController, _ appState: AppState
    ) async -> String? {
        var delivered: String?
        controller.onFinalTranscript = { delivered = $0 }
        controller.start()
        controller.stop()
        await waitUntil { appState.phase == .idle }
        return delivered
    }

    @MainActor
    func testFormattingOffNeverCallsFormat() async throws {
        let engine = FormatMockEngine()
        let (controller, appState, _) = try makeController(engine: engine)
        // Default settings: formatFinalTranscript == false.
        controller.formatterModelPath = { "/tmp/never-used" }
        let delivered = await runSession(controller, appState)
        XCTAssertEqual(delivered, " raw transcript")
        let calls = await engine.formatCalls
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testFormattedTranscriptIsDelivered() async throws {
        let engine = FormatMockEngine()
        let (controller, appState, settings) = try makeController(engine: engine)
        settings.formatFinalTranscript = true
        controller.formatterModelPath = { "/tmp/formatter-model" }
        let delivered = await runSession(controller, appState)
        // Formatted text, with the autoSpacing separator applied on top.
        XCTAssertEqual(delivered, " Polished transcript.")
        XCTAssertEqual(appState.lastTranscript, " Polished transcript.")
        let calls = await engine.formatCalls
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testFormatFailureFallsBackToRaw() async throws {
        let engine = FormatMockEngine()
        await engine.setBehavior(.fail)
        let (controller, appState, settings) = try makeController(engine: engine)
        settings.formatFinalTranscript = true
        controller.formatterModelPath = { "/tmp/formatter-model" }
        let delivered = await runSession(controller, appState)
        XCTAssertEqual(delivered, " raw transcript")
    }

    @MainActor
    func testFormatTimeoutFallsBackToRaw() async throws {
        let engine = FormatMockEngine()
        await engine.setBehavior(.hang)
        let (controller, appState, settings) = try makeController(engine: engine)
        settings.formatFinalTranscript = true
        controller.formatterModelPath = { "/tmp/formatter-model" }
        controller.formatTimeoutSeconds = 0.2
        let started = Date()
        let delivered = await runSession(controller, appState)
        XCTAssertEqual(delivered, " raw transcript")
        // The raw text must arrive at ~the timeout, not after the 60 s hang:
        // the group's implicit drain only returns promptly because cancelAll()
        // genuinely cancels the format child.
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        await waitUntil { await engine.formatCancelled }
        // `finalizing` cleared — a new press may begin immediately.
        controller.start()
        XCTAssertTrue(controller.isRunning)
        controller.cancel()
    }

    @MainActor
    func testNoFormatterInstalledSkipsFormatting() async throws {
        let engine = FormatMockEngine()
        let (controller, appState, settings) = try makeController(engine: engine)
        settings.formatFinalTranscript = true
        controller.formatterModelPath = { nil }   // "not installed"
        let delivered = await runSession(controller, appState)
        XCTAssertEqual(delivered, " raw transcript")
        let calls = await engine.formatCalls
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testCapabilityTogglesReachTheEngine() async throws {
        let engine = FormatMockEngine()
        let (controller, appState, settings) = try makeController(engine: engine)
        settings.formatFinalTranscript = true
        settings.formatterRemovesFillers = false
        settings.formatterFormatsLists = true
        settings.formatterAppliesCorrections = false
        controller.formatterModelPath = { "/tmp/formatter-model" }
        _ = await runSession(controller, appState)
        let options = await engine.lastOptions
        XCTAssertEqual(options, FormatterOptions(
            removesFillers: false, formatsLists: true, appliesCorrections: false))
    }

    func testPolishingPhaseLabel() {
        XCTAssertEqual(DictationPhase.polishing.label, "Polishing…")
        XCTAssertTrue(DictationPhase.polishing.isActive)
    }

    // MARK: warmFormatterIfNeeded triggers

    @MainActor
    func testWarmFormatterSendsWarmWhenEnabledAndInstalled() async throws {
        let engine = FormatMockEngine()
        let (controller, _, settings) = try makeController(engine: engine)
        settings.formatFinalTranscript = true
        controller.formatterModelPath = { "/tmp/formatter-model" }
        controller.warmFormatterIfNeeded()
        await waitUntil { await engine.warmCalls == ["/tmp/formatter-model"] }
    }

    @MainActor
    func testWarmFormatterIsDebouncedPerPath() async throws {
        let engine = FormatMockEngine()
        let (controller, _, settings) = try makeController(engine: engine)
        settings.formatFinalTranscript = true
        controller.formatterModelPath = { "/tmp/formatter-model" }
        controller.warmFormatterIfNeeded()
        controller.warmFormatterIfNeeded()   // same path → no second send
        await waitUntil { await engine.warmCalls.count == 1 }
        try? await Task.sleep(nanoseconds: 30_000_000)
        let calls = await engine.warmCalls
        XCTAssertEqual(calls, ["/tmp/formatter-model"])
    }

    @MainActor
    func testWarmFormatterSkippedWhenSettingOff() async throws {
        let engine = FormatMockEngine()
        let (controller, _, _) = try makeController(engine: engine)
        // Default settings: formatFinalTranscript == false.
        controller.formatterModelPath = { "/tmp/formatter-model" }
        controller.warmFormatterIfNeeded()
        try? await Task.sleep(nanoseconds: 30_000_000)
        let calls = await engine.warmCalls
        XCTAssertEqual(calls, [])
    }

    @MainActor
    func testWarmFormatterSkippedWhenNotInstalled() async throws {
        let engine = FormatMockEngine()
        let (controller, _, settings) = try makeController(engine: engine)
        settings.formatFinalTranscript = true
        controller.formatterModelPath = { nil }   // "not installed"
        controller.warmFormatterIfNeeded()
        try? await Task.sleep(nanoseconds: 30_000_000)
        let calls = await engine.warmCalls
        XCTAssertEqual(calls, [])
    }

    @MainActor
    func testWarmFormatterFiresAgainAfterInstallAppears() async throws {
        // Setting on but model missing → no warm; once the path resolves
        // (download completed), the next trigger warms.
        let engine = FormatMockEngine()
        let (controller, _, settings) = try makeController(engine: engine)
        settings.formatFinalTranscript = true
        let installed = SendableBox<String?>(nil)
        controller.formatterModelPath = { installed.value }
        controller.warmFormatterIfNeeded()
        try? await Task.sleep(nanoseconds: 30_000_000)
        installed.value = "/tmp/formatter-model"
        controller.warmFormatterIfNeeded()
        await waitUntil { await engine.warmCalls == ["/tmp/formatter-model"] }
    }

    @MainActor
    func testWarmFormatterCarriesUserOptions() async throws {
        // The warm-up must anchor the prefix cache for the user's REAL
        // toggles — warming defaults would re-anchor on the first format.
        let engine = FormatMockEngine()
        let (controller, _, settings) = try makeController(engine: engine)
        settings.formatFinalTranscript = true
        settings.formatterRemovesFillers = false
        settings.formatterAppliesCorrections = false
        controller.formatterModelPath = { "/tmp/formatter-model" }
        controller.warmFormatterIfNeeded()
        await waitUntil { await engine.warmOptions.count == 1 }
        let options = await engine.warmOptions.first
        XCTAssertEqual(options, FormatterOptions(
            removesFillers: false, formatsLists: true, appliesCorrections: false))
    }

    @MainActor
    func testWarmFormatterReWarmsWhenOptionsChange() async throws {
        // Same path but different toggles is NOT debounced — the anchor must
        // follow the options.
        let engine = FormatMockEngine()
        let (controller, _, settings) = try makeController(engine: engine)
        settings.formatFinalTranscript = true
        controller.formatterModelPath = { "/tmp/formatter-model" }
        controller.warmFormatterIfNeeded()
        await waitUntil { await engine.warmCalls.count == 1 }
        settings.formatterFormatsLists = false
        controller.warmFormatterIfNeeded()
        await waitUntil { await engine.warmCalls.count == 2 }
        let options = await engine.warmOptions.last
        XCTAssertEqual(options?.formatsLists, false)
    }

    // MARK: cancel() during the finalize/polish window

    @MainActor
    func testCancelDuringPolishingDropsDeliveryAndAllowsRestart() async throws {
        let engine = FormatMockEngine()
        await engine.setBehavior(.hang)
        let (controller, appState, settings) = try makeController(engine: engine)
        settings.formatFinalTranscript = true
        controller.formatterModelPath = { "/tmp/formatter-model" }
        controller.formatTimeoutSeconds = 0.3
        var delivered: String?
        controller.onFinalTranscript = { delivered = $0 }
        controller.start()
        controller.stop()
        await waitUntil { appState.phase == .polishing }

        controller.cancel()
        XCTAssertEqual(appState.phase, .idle)
        await waitUntil { await engine.cancelCalls >= 1 }
        // Wait out the polish timeout: the stale stop-task must NOT deliver,
        // commit, or count telemetry for the cancelled utterance.
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertNil(delivered)
        XCTAssertEqual(appState.lastTranscript, "")

        // And a new session may begin immediately (finalizing was cleared).
        controller.start()
        XCTAssertTrue(controller.isRunning)
        controller.cancel()
    }

    // MARK: unloadFormatterIfIdle

    @MainActor
    func testUnloadAfterWarmSendsUnloadOnceAndReArmsWarm() async throws {
        let engine = FormatMockEngine()
        let (controller, _, settings) = try makeController(engine: engine)
        settings.formatFinalTranscript = true
        controller.formatterModelPath = { "/tmp/formatter-model" }
        controller.warmFormatterIfNeeded()
        await waitUntil { await engine.warmCalls.count == 1 }

        controller.unloadFormatterIfIdle()
        await waitUntil { await engine.unloadCalls == 1 }
        // Debounced: nothing can be resident anymore → a re-fired trigger
        // (e.g. install-phase churn) sends nothing.
        controller.unloadFormatterIfIdle()
        try? await Task.sleep(nanoseconds: 30_000_000)
        let unloads = await engine.unloadCalls
        XCTAssertEqual(unloads, 1)

        // The warm debounce was cleared — re-enabling re-warms.
        controller.warmFormatterIfNeeded()
        await waitUntil { await engine.warmCalls.count == 2 }
    }

    @MainActor
    func testUnloadSkippedWhileSessionActive() async throws {
        let engine = FormatMockEngine()
        let (controller, _, settings) = try makeController(engine: engine)
        settings.formatFinalTranscript = true
        controller.formatterModelPath = { "/tmp/formatter-model" }
        controller.warmFormatterIfNeeded()
        await waitUntil { await engine.warmCalls.count == 1 }

        controller.start()
        XCTAssertTrue(controller.isRunning)
        controller.unloadFormatterIfIdle()   // mid-session: must not unload
        try? await Task.sleep(nanoseconds: 30_000_000)
        let unloads = await engine.unloadCalls
        XCTAssertEqual(unloads, 0)
        controller.cancel()
    }

    @MainActor
    func testUnloadWithoutAnythingResidentIsANoOp() async throws {
        let engine = FormatMockEngine()
        let (controller, _, _) = try makeController(engine: engine)
        controller.unloadFormatterIfIdle()   // never warmed, never formatted
        try? await Task.sleep(nanoseconds: 30_000_000)
        let unloads = await engine.unloadCalls
        XCTAssertEqual(unloads, 0)
    }

    // MARK: end-of-session residency sync

    @MainActor
    func testToggleOffMidSessionUnloadsAfterStop() async throws {
        // Formatting is toggled OFF while a session runs: the Observation
        // trigger fires mid-session (refused — formatter may be mid-use) and
        // never again, so the end-of-session sync must send the unload.
        let engine = FormatMockEngine()
        let (controller, appState, settings) = try makeController(engine: engine)
        settings.formatFinalTranscript = true
        controller.formatterModelPath = { "/tmp/formatter-model" }
        controller.warmFormatterIfNeeded()
        await waitUntil { await engine.warmCalls.count == 1 }

        controller.start()
        settings.formatFinalTranscript = false      // user toggles OFF mid-session
        controller.unloadFormatterIfIdle()          // the app's trigger — refused now
        try? await Task.sleep(nanoseconds: 30_000_000)
        var unloads = await engine.unloadCalls
        XCTAssertEqual(unloads, 0, "mid-session unload must be refused")

        controller.stop()
        await waitUntil { appState.phase == .idle }
        await waitUntil { await engine.unloadCalls == 1 }
        // And the decision is single: no format ran (setting off at stop).
        let formats = await engine.formatCalls
        XCTAssertEqual(formats, 0)
        unloads = await engine.unloadCalls
        XCTAssertEqual(unloads, 1)
    }

    @MainActor
    func testToggleOffMidSessionUnloadsAfterCancel() async throws {
        // Same hole via the other session exit: cancel() clears `finalizing`
        // without running the stop-task's completion path.
        let engine = FormatMockEngine()
        let (controller, _, settings) = try makeController(engine: engine)
        settings.formatFinalTranscript = true
        controller.formatterModelPath = { "/tmp/formatter-model" }
        controller.warmFormatterIfNeeded()
        await waitUntil { await engine.warmCalls.count == 1 }

        controller.start()
        settings.formatFinalTranscript = false
        controller.cancel()
        await waitUntil { await engine.unloadCalls == 1 }
    }

    @MainActor
    func testSessionEndKeepsFormatterWarmWhenStillEnabled() async throws {
        // The end-of-session sync must decide "nothing to do" when formatting
        // stays on: no unload, no duplicate warm (debounced by path+options).
        let engine = FormatMockEngine()
        let (controller, appState, settings) = try makeController(engine: engine)
        settings.formatFinalTranscript = true
        controller.formatterModelPath = { "/tmp/formatter-model" }
        controller.warmFormatterIfNeeded()
        await waitUntil { await engine.warmCalls.count == 1 }

        controller.start()
        controller.stop()
        await waitUntil { appState.phase == .idle }
        try? await Task.sleep(nanoseconds: 30_000_000)
        let unloads = await engine.unloadCalls
        let warms = await engine.warmCalls
        XCTAssertEqual(unloads, 0)
        XCTAssertEqual(warms, ["/tmp/formatter-model"])
    }

    // MARK: warm/unload ordering

    @MainActor
    func testResidencySendsReachTheEngineInDecisionOrder() async throws {
        // warm → unload → warm issued back-to-back: each send chains on the
        // previous (`residencyTask`), so the mock's slow warm cannot be
        // overtaken by the following unload.
        let engine = FormatMockEngine()
        let (controller, _, settings) = try makeController(engine: engine)
        settings.formatFinalTranscript = true
        controller.formatterModelPath = { "/tmp/formatter-model" }
        controller.warmFormatterIfNeeded()
        controller.unloadFormatterIfIdle()
        controller.warmFormatterIfNeeded()
        await waitUntil { await engine.residencyEvents.count == 3 }
        let events = await engine.residencyEvents
        XCTAssertEqual(events, ["warm", "unload", "warm"])
    }
}

/// Tiny lock-free-enough box for test closures (main-actor confined use).
private final class SendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Serialized generation queue (model-free)

/// Ordered event recorder for queue tests.
private actor EventLog {
    private(set) var all: [String] = []
    func add(_ event: String) { all.append(event) }
}

final class FormatterSerializedQueueTests: XCTestCase {
    /// `unload()` runs `dropResidentState`, which drops the queue-tail handle
    /// — but ONLY when the unload itself is the tail. If work was queued
    /// behind the unload, nilling the tail would sever the serialization
    /// chain and let two later ops interleave: op C (enqueued after the
    /// unload finished) must still wait for op B (enqueued before).
    func testUnloadPreservesQueueOrderForLaterOps() async throws {
        let formatter = TranscriptFormatter(
            directory: URL(fileURLWithPath: "/nonexistent-model-dir"))
        let events = EventLog()

        // A (slow) … unload … B (slow, queued BEHIND the unload).
        let a = Task {
            await formatter.enqueueSerializedForTesting {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await events.add("A")
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let unload = Task { await formatter.unload() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let b = Task {
            await formatter.enqueueSerializedForTesting {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await events.add("B")
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        // Once the unload has finished (B is still sleeping), a fresh op must
        // queue behind B — with a severed chain it would run immediately.
        await unload.value
        await formatter.enqueueSerializedForTesting { await events.add("C") }
        await a.value
        await b.value
        let all = await events.all
        XCTAssertEqual(all, ["A", "B", "C"])
    }

    /// The normal case still tears the queue down: an unload with nothing
    /// queued behind it must not leave a stale tail handle pinning captures.
    func testUnloadAloneStillRunsAndLaterOpsWork() async throws {
        let formatter = TranscriptFormatter(
            directory: URL(fileURLWithPath: "/nonexistent-model-dir"))
        let events = EventLog()
        await formatter.unload()
        await formatter.enqueueSerializedForTesting { await events.add("after") }
        let all = await events.all
        XCTAssertEqual(all, ["after"])
    }
}

// MARK: - Prefix-cache anchor arithmetic (pure)

final class FormatterPrefixReuseTests: XCTestCase {
    func testSharedPrefixOfSentinelRenders() {
        // Two renders differing only in the user turn share the preamble.
        XCTAssertEqual(
            TranscriptFormatter.sharedPrefixLength([1, 2, 3, 40, 9], [1, 2, 3, 41, 9]), 3)
    }

    func testDisjointSequencesShareNothing() {
        XCTAssertEqual(TranscriptFormatter.sharedPrefixLength([7, 8], [1, 2, 3]), 0)
    }

    func testIdenticalSequencesShareEverything() {
        XCTAssertEqual(TranscriptFormatter.sharedPrefixLength([1, 2, 3], [1, 2, 3]), 3)
    }

    func testEmptySequenceIsSafe() {
        XCTAssertEqual(TranscriptFormatter.sharedPrefixLength([], [1, 2]), 0)
        XCTAssertEqual(TranscriptFormatter.sharedPrefixLength([1], []), 0)
    }
}
