// Pure transcript-windowing for the HUD — no SwiftUI, so it's portable and
// unit-testable (mirrors RecordingProgress). The live transcript can grow without
// bound; the HUD only wants the most recent tail so the text stays a steady size
// and the newest words don't wander around the box. This slices that tail off the
// front verbatim, so the retained text keeps its exact spacing/newlines and barely
// moves as words arrive.

import Foundation

public enum TranscriptWindow {
    /// Returns at most the last `maxWords` whitespace-delimited words of `text`.
    /// When earlier words are dropped, the result is prefixed with `ellipsis` ("… ").
    ///
    /// The RETAINED TAIL keeps its ORIGINAL characters/whitespace/newlines verbatim —
    /// we only slice off the front; we never re-join words (that would reflow
    /// formatting and make the live text jump around).
    ///
    /// "Words" = maximal runs of non-whitespace, matching
    /// `DictationController.wordCount`. Text with `<= maxWords` words is returned
    /// unchanged (no ellipsis).
    public static func lastWords(_ text: String, maxWords: Int = 50, ellipsis: String = "… ") -> String {
        guard maxWords > 0 else { return "" }

        // Single O(n) scan from the end. A "word start" is a non-whitespace
        // character whose left neighbour is whitespace or the string start (the
        // first character of a maximal non-whitespace run). We keep the last
        // `maxWords` of them: `sliceStart` is set when we reach the maxWords-th
        // word start from the end; the moment we then find one MORE word start we
        // know an earlier word exists, so the tail is a genuine truncation and
        // earns the ellipsis. If the scan reaches the start first, there were
        // `<= maxWords` words and we return the text unchanged.
        var wordStarts = 0
        var sliceStart: String.Index?
        var index = text.endIndex

        while index > text.startIndex {
            let prev = text.index(before: index)
            if !text[prev].isWhitespace {
                let isWordStart = prev == text.startIndex || text[text.index(before: prev)].isWhitespace
                if isWordStart {
                    wordStarts += 1
                    if wordStarts == maxWords {
                        sliceStart = prev
                    } else if wordStarts > maxWords, let sliceStart {
                        return ellipsis + String(text[sliceStart...])
                    }
                }
            }
            index = prev
        }

        // Fewer than (or exactly) `maxWords` words ⇒ nothing dropped.
        return text
    }
}
