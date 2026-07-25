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
