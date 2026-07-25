// Turns dry totals into something you can feel.
//
// "4h 12min" means little; "≈ 1.3× the movie Titanic 🚢" lands. This picks a
// relatable anchor that scales with the total — a voicemail when you've barely
// started, an epic when you've dictated for days — for both time and words.
// Pure and portable so it's trivially unit-testable and reusable on iOS.

import Foundation

/// A relatable yardstick and how the user's total compares to it.
public struct UsageEquivalent: Sendable, Equatable {
    /// The reference thing, e.g. "the movie Titanic".
    public let name: String
    /// A decorative emoji for the reference.
    public let emoji: String
    /// total ÷ reference. ≥ 1 means "you've exceeded one of these".
    public let multiple: Double

    /// "1.3× the movie Titanic" / "half of a pop song" / "12× a work day".
    public var phrase: String {
        "\(Self.formatMultiple(multiple)) \(name)"
    }

    /// Compact multiplier: "half of", "1.3×", "12×", "340×".
    static func formatMultiple(_ x: Double) -> String {
        if x < 0.15 { return "a sliver of" }
        if x < 0.42 { return "a third of" }
        if x < 0.7 { return "half of" }
        if x < 0.9 { return "most of" }
        if x < 1.15 { return "about" }        // ~1× reads as "about <thing>"
        if x < 10 {
            // One decimal, but drop a trailing ".0".
            let s = String(format: "%.1f", x)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + "×"
        }
        return "\(Int(x.rounded()))×"
    }
}

public enum UsageEquivalents {
    // MARK: Duration anchors (seconds), smallest → largest.

    /// Reference runtimes people know by feel. Ordered ascending; the picker
    /// chooses the largest one the total has surpassed (or the smallest, framed
    /// as a fraction, before you've cleared even that).
    static let durationAnchors: [(name: String, emoji: String, seconds: Double)] = [
        ("a voicemail",                    "📞", 30),
        ("the Gettysburg Address",         "🎩", 2 * 60),                // ~2 min; Lincoln's 272-word address, per history.com/articles/gettysburg-address
        ("the song Bohemian Rhapsody",     "🎸", 5 * 60 + 55),          // 5:55; per en.wikipedia.org/wiki/Bohemian_Rhapsody
        ("the song American Pie",          "🥧", 8 * 60 + 37),          // 8:37 (album version); per en.wikipedia.org/wiki/American_Pie_(song)
        ("MLK's \"I Have a Dream\" speech","🎙️", 17 * 60),              // ~17 min, delivered Aug 28 1963; per usembassy / naacp.org accounts
        ("a sitcom episode",               "📺", 22 * 60),              // ~22 min sans ads (e.g. Friends); per en.wikipedia.org/wiki/List_of_Friends_episodes
        ("The Godfather",                  "🎬", 175 * 60),             // 2h55m (175 min); per en.wikipedia.org/wiki/The_Godfather
        ("Avengers: Endgame",              "🦸", 181 * 60),             // ~3h01m (181 min); per indiewire.com Endgame runtime report
        ("the movie Titanic",              "🚢", 3 * 3600 + 14 * 60),   // 3h14m (194 min)
        ("Gone with the Wind",             "🌪️", 3 * 3600 + 58 * 60),  // 3h58m (238 min, incl. overture & intermission); per en.wikipedia.org/wiki/Gone_with_the_Wind_(film)
        ("the Lord of the Rings trilogy",  "💍", 11 * 3600 + 22 * 60),  // extended editions, 11h22m (682 min); per looper.com LOTR runtimes
        ("a full audiobook",               "🎧", 16 * 3600),
        ("a work week",                    "💼", 40 * 3600),
        ("a full month of workdays",       "📆", 160 * 3600),
        ("a solid year of talking",        "🗓️", 365.0 * 24 * 3600),
    ]

    // MARK: Word-count anchors, smallest → largest.

    static let wordAnchors: [(name: String, emoji: String, words: Double)] = [
        ("a text message",                 "💬", 7),          // avg SMS ≈ 7 words; per crushhapp.com "average text message length"
        ("a tweet",                        "🐦", 50),         // 280 chars ≈ ~50 words
        ("a postcard",                     "✉️", 100),
        ("a typical news article",         "📰", 800),        // online news piece ≈ 600–900 words; using 800 as the midpoint
        ("a blog post",                    "📝", 1_000),
        ("the Declaration of Independence","📜", 1_320),      // 1,320 words; per declaration.fas.harvard.edu (Harvard Declaration Resources Project)
        ("the U.S. Constitution",          "📃", 4_543),      // 4,543 words, original unamended incl. signatures; per usconstitution.net / National Constitution Center
        ("a long magazine feature",        "🗞️", 6_000),     // long-form feature ≈ 5,000–10,000 words; using 6,000
        ("a short story",                  "📖", 7_500),
        ("a novella",                      "📗", 30_000),
        ("The Great Gatsby",               "🥂", 47_094),     // 47,094 words; per wordcounttool.com famous-novels list
        ("Harry Potter and the Sorcerer's Stone", "⚡️", 76_944),   // 76,944 words; per hogwartsprofessor.com "Harry Potter by the Numbers"
        ("a full-length novel",            "📚", 90_000),
        ("The Lord of the Rings",          "🗺️", 481_103),    // 481,103 words; per sacnoths.blogspot.com / wordcounters
        ("War and Peace",                  "⚔️", 587_287),    // 587,287 words; per wordcounter.net
        ("the entire Harry Potter series", "🧙", 1_084_170),  // 1,084,170 words; per hogwartsprofessor.com
    ]

    // MARK: Pickers

    /// The most fitting duration equivalent for `totalSeconds`.
    /// Returns nil only when there's genuinely nothing yet (≤ 0).
    public static func forDuration(seconds totalSeconds: Double) -> UsageEquivalent? {
        pick(total: totalSeconds, anchors: durationAnchors.map { ($0.name, $0.emoji, $0.seconds) })
    }

    /// The most fitting word-count equivalent for `totalWords`.
    public static func forWords(_ totalWords: Int) -> UsageEquivalent? {
        pick(total: Double(totalWords), anchors: wordAnchors.map { ($0.name, $0.emoji, $0.words) })
    }

    /// Shared selection: the largest anchor the total has reached, else the
    /// smallest (framed as a fraction). The top anchor ("a solid year of
    /// talking") is large enough that real usage keeps the multiple readable.
    private static func pick(
        total: Double, anchors: [(name: String, emoji: String, value: Double)]
    ) -> UsageEquivalent? {
        guard total > 0, !anchors.isEmpty else { return nil }
        // Largest anchor whose value ≤ total → a multiple ≥ 1.
        if let anchor = anchors.last(where: { $0.value <= total }) {
            return UsageEquivalent(name: anchor.name, emoji: anchor.emoji,
                                   multiple: total / anchor.value)
        }
        // Below even the smallest anchor: report it as a fraction.
        let smallest = anchors[0]
        return UsageEquivalent(name: smallest.name, emoji: smallest.emoji,
                               multiple: total / smallest.value)
    }
}
