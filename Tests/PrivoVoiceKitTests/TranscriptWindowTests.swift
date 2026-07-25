// Unit tests for TranscriptWindow.lastWords — the pure tail-windowing the HUD
// uses to show only the most recent words. These pin the two load-bearing
// promises: nothing is dropped when the text is short enough, and when it IS
// dropped the retained tail is preserved VERBATIM (original spacing/newlines)
// behind a leading "… ".

import XCTest
import Foundation
@testable import PrivoVoiceKit

final class TranscriptWindowTests: XCTestCase {

    private func words(_ n: Int) -> String {
        (1...n).map { "word\($0)" }.joined(separator: " ")
    }

    // MARK: - Nothing to drop

    func testShortTextUnchanged() {
        let text = "add milk and eggs to the list"
        XCTAssertEqual(TranscriptWindow.lastWords(text, maxWords: 50), text)
    }

    func testExactlyMaxWordsUnchanged() {
        let text = words(50)
        // Exactly at the cap ⇒ no truncation, no ellipsis.
        XCTAssertEqual(TranscriptWindow.lastWords(text, maxWords: 50), text)
    }

    func testFewerThanMaxWordsUnchanged() {
        let text = words(3)
        XCTAssertEqual(TranscriptWindow.lastWords(text, maxWords: 50), text)
    }

    func testEmptyString() {
        XCTAssertEqual(TranscriptWindow.lastWords("", maxWords: 50), "")
    }

    func testWhitespaceOnlyUnchanged() {
        let text = "   \n\t  "
        // No words at all ⇒ returned verbatim, no ellipsis.
        XCTAssertEqual(TranscriptWindow.lastWords(text, maxWords: 50), text)
    }

    // MARK: - Dropping the front

    func testOverMaxWordsGetsEllipsisAndExactTail() {
        let text = words(51)               // word1 … word51
        let result = TranscriptWindow.lastWords(text, maxWords: 50)
        // Keep the last 50 (word2 … word51), prefixed with the ellipsis.
        XCTAssertEqual(result, "… " + words51Tail())
    }

    private func words51Tail() -> String {
        (2...51).map { "word\($0)" }.joined(separator: " ")
    }

    func testTailPreservesOriginalSpacing() {
        // word1 word2 word3 word4  word5   word6  — irregular spacing in the tail
        // must survive verbatim; only the front is sliced.
        let text = "one two three  four   five"
        let result = TranscriptWindow.lastWords(text, maxWords: 3)
        XCTAssertEqual(result, "… three  four   five")
    }

    func testTailPreservesNewlines() {
        let text = "alpha beta gamma\ndelta epsilon"
        // Keep last 3 words: gamma, delta, epsilon — the newline between gamma and
        // delta is inside the retained tail and must be kept.
        let result = TranscriptWindow.lastWords(text, maxWords: 3)
        XCTAssertEqual(result, "… gamma\ndelta epsilon")
    }

    func testTrailingWhitespacePreservedInTail() {
        let text = "a b c   "
        let result = TranscriptWindow.lastWords(text, maxWords: 2)
        XCTAssertEqual(result, "… b c   ")
    }

    func testLeadingWhitespaceIsSlicedOffWithDroppedFront() {
        let text = "   a b c d"
        let result = TranscriptWindow.lastWords(text, maxWords: 2)
        // The leading spaces and the dropped words all go; tail starts at "c".
        XCTAssertEqual(result, "… c d")
    }

    // MARK: - Custom maxWords / ellipsis

    func testCustomMaxWords() {
        let text = words(10)
        let result = TranscriptWindow.lastWords(text, maxWords: 4)
        XCTAssertEqual(result, "… " + (7...10).map { "word\($0)" }.joined(separator: " "))
    }

    func testCustomEllipsis() {
        let text = "one two three four"
        let result = TranscriptWindow.lastWords(text, maxWords: 2, ellipsis: "...")
        XCTAssertEqual(result, "...three four")
    }

    func testSingleWordWindow() {
        let text = "one two three"
        XCTAssertEqual(TranscriptWindow.lastWords(text, maxWords: 1), "… three")
    }
}
