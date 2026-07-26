// Which optional cleanup capabilities the transcript formatter applies, mapped
// 1:1 from the three user toggles in Settings. Baseline cleanup (punctuation,
// capitalization, obvious transcription-error fixes) is always on whenever
// formatting itself is on; these gate the more opinionated edits.
//
// Codable + Sendable so the selection can cross the IPC boundary to the
// sidecar unchanged.

import Foundation

public struct FormatterOptions: Sendable, Equatable, Codable {
    /// Remove disfluencies: filler words (um, uh, ah, er, hmm) and stutters.
    public var removesFillers: Bool
    /// Format spoken enumerations ("first … second …") as lists.
    public var formatsLists: Bool
    /// Apply verbal self-corrections ("monday no wait tuesday" → "Tuesday").
    public var appliesCorrections: Bool

    public init(
        removesFillers: Bool = true,
        formatsLists: Bool = true,
        appliesCorrections: Bool = true
    ) {
        self.removesFillers = removesFillers
        self.formatsLists = formatsLists
        self.appliesCorrections = appliesCorrections
    }
}
