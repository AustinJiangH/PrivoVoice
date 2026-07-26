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

    @MainActor
    func testFreshStoreIsNotInstalled() throws {
        let store = FormatterStore(rootDirectory: try makeRoot())
        XCTAssertEqual(store.phase, .notInstalled)
        XCTAssertFalse(store.isInstalled)
    }

    @MainActor
    func testDetectsInstalledSnapshotOnInit() throws {
        let root = try makeRoot()
        let dir = root.appending(path: FormatterCatalog.installSlug, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appending(path: "config.json"))
        try Data("w".utf8).write(to: dir.appending(path: "model.safetensors"))

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
    func testRemoveResetsPhaseAndDeletes() async throws {
        let root = try makeRoot()
        let dir = root.appending(path: FormatterCatalog.installSlug, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appending(path: "config.json"))
        try Data("w".utf8).write(to: dir.appending(path: "model.safetensors"))

        let store = FormatterStore(rootDirectory: root)
        XCTAssertTrue(store.isInstalled)
        store.remove()
        XCTAssertEqual(store.phase, .notInstalled)
        // The delete itself runs off the main actor — poll briefly.
        let deadline = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: dir.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}

// MARK: - Controller polish path

/// A `DictationEngine` fake whose `format` behavior is scripted per test.
actor FormatMockEngine: DictationEngine {
    enum FormatBehavior {
        case succeed(String)
        case fail
        case hang            // never returns (until task cancellation)
    }
    var finalText = "raw transcript"
    var behavior: FormatBehavior = .succeed("Polished transcript.")
    private(set) var formatCalls = 0

    func setBehavior(_ b: FormatBehavior) { behavior = b }
    func setFinal(_ t: String) { finalText = t }

    func begin(modelURL: URL, backend: ModelBackend, locale: Locale,
               format: AudioStreamFormat, onPartial: @escaping @Sendable (String) -> Void) async throws {}
    func feed(_ samples: [Float]) {}
    func end() async throws -> String { finalText }
    func cancel() {}

    private(set) var lastOptions: FormatterOptions?

    func format(text: String, modelPath: String, options: FormatterOptions) async throws -> String {
        formatCalls += 1
        lastOptions = options
        switch behavior {
        case .succeed(let t): return t
        case .fail: throw Boom()
        case .hang:
            try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
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
        let delivered = await runSession(controller, appState)
        XCTAssertEqual(delivered, " raw transcript")
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
}
