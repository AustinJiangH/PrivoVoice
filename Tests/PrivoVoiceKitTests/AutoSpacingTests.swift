// Unit tests for the auto-spacing separator helper and KeyCombo badge
// decomposition — both pure/Foundation-only, no controller lifecycle or AppKit.

import XCTest
@testable import PrivoVoiceKit

final class AutoSpacingTests: XCTestCase {

    // MARK: DictationController.separated

    func testSeparatedEmptyStaysEmpty() {
        XCTAssertEqual(DictationController.separated(""), "")
    }

    func testSeparatedPrependsOneSpace() {
        XCTAssertEqual(DictationController.separated("sentence"), " sentence")
    }

    func testSeparatedLeavesLeadingWhitespaceUnchanged() {
        XCTAssertEqual(DictationController.separated(" already"), " already")
        XCTAssertEqual(DictationController.separated("\tindented"), "\tindented")
        XCTAssertEqual(DictationController.separated("\nnewline"), "\nnewline")
    }

    func testSeparatedNormalSentence() {
        XCTAssertEqual(DictationController.separated("Hello, world."), " Hello, world.")
    }

    func testSeparatedMultilineListPrependsNewline() {
        // A formatted list must start on its own line — a space separator
        // would glue "Intro." (and item 1) onto the previous line's prose.
        XCTAssertEqual(
            DictationController.separated("Intro.\n1. First item.\n2. Second item."),
            "\nIntro.\n1. First item.\n2. Second item.")
    }

    func testSeparatedMultilineWithLeadingWhitespaceUnchanged() {
        // Idempotency holds for lists too: an already-separated list is
        // returned unchanged.
        XCTAssertEqual(
            DictationController.separated("\nIntro.\n1. Item."),
            "\nIntro.\n1. Item.")
    }

    // MARK: KeyCombo.badgeComponents

    func testBadgeComponentsFunctionOnly() {
        let combo = KeyCombo(keyCode: nil, modifiers: [.function])
        XCTAssertEqual(combo.badgeComponents, ["fn"])
    }

    func testBadgeComponentsOptionSpace() {
        let combo = KeyCombo(keyCode: 49, keyLabel: "Space", modifiers: [.option])
        XCTAssertEqual(combo.badgeComponents, ["⌥", "Space"])
    }

    func testBadgeComponentsControlM() {
        let combo = KeyCombo(keyCode: 46, keyLabel: "M", modifiers: [.control])
        XCTAssertEqual(combo.badgeComponents, ["⌃", "M"])
    }

    func testBadgeComponentsEmpty() {
        let combo = KeyCombo(keyCode: nil, modifiers: [])
        XCTAssertEqual(combo.badgeComponents, [])
    }

    func testBadgeComponentsCanonicalOrder() {
        // fn, ⌃, ⌥, ⇧, ⌘ then key label — regardless of insertion order.
        let combo = KeyCombo(
            keyCode: 49, keyLabel: "Space",
            modifiers: [.command, .shift, .option, .control, .function])
        XCTAssertEqual(combo.badgeComponents, ["fn", "⌃", "⌥", "⇧", "⌘", "Space"])
    }
}
