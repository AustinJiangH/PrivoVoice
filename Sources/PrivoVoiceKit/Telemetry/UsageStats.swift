// On-device usage aggregates that power the Dashboard.
//
// Everything here is computed and stored LOCALLY. It never leaves the Mac unless
// the user explicitly turns on opt-in telemetry (see `Telemetry` / `AppSettings`).
// Persisted as JSON next to settings, following the same debounced-save pattern
// as `AppSettings`, and kept in PrivoVoiceKit so a future iOS app reuses it.

import Foundation
import Observation

@MainActor
@Observable
public final class UsageStats {
    /// Total seconds of audio transcribed across every completed dictation.
    public private(set) var totalSeconds: Double
    /// Total words committed (pasted) across every completed dictation.
    public private(set) var totalWords: Int
    /// Number of completed dictations (non-empty transcripts).
    public private(set) var totalSessions: Int
    /// A random, anonymous install identifier — device metadata for opt-in
    /// reports so a collector can de-duplicate installs. Generated once, locally;
    /// it says nothing about who the user is.
    public let installID: String

    private var saveScheduled = false
    private let storeURL: URL

    /// `~/Library/Application Support/PrivoVoice/usage.json`.
    public static var defaultStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base.appending(path: "PrivoVoice/usage.json")
    }

    // MARK: Init / persistence

    public init(storeURL: URL = UsageStats.defaultStoreURL) {
        self.storeURL = storeURL
        var needsInitialSave = true
        if let persisted = try? Persisted.load(from: storeURL) {
            self.totalSeconds = max(0, persisted.totalSeconds ?? 0)
            self.totalWords = max(0, persisted.totalWords ?? 0)
            self.totalSessions = max(0, persisted.totalSessions ?? 0)
            if let id = persisted.installID {
                self.installID = id
                needsInitialSave = false   // already on disk; don't rewrite each launch
            } else {
                self.installID = UUID().uuidString   // upgrade from a pre-installID file
            }
        } else {
            self.totalSeconds = 0
            self.totalWords = 0
            self.totalSessions = 0
            self.installID = UUID().uuidString
        }
        // Property observers don't run inside init; persist the freshly-generated
        // installID once so it's stable across launches. A clean load skips this.
        if needsInitialSave { saveNow() }
    }

    // MARK: Mutation

    /// Fold one completed dictation into the running totals. Negatives are
    /// clamped to zero so a bad measurement can never corrupt the aggregates.
    public func record(seconds: Double, words: Int) {
        totalSeconds += max(0, seconds)
        totalWords += max(0, words)
        totalSessions += 1
        scheduleSave()
    }

    /// Wipe the local totals (keeps the anonymous install ID).
    public func reset() {
        totalSeconds = 0
        totalWords = 0
        totalSessions = 0
        saveNow()
    }

    // MARK: Save

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { @MainActor in
            self.saveScheduled = false
            self.saveNow()
        }
    }

    public func saveNow() {
        let snapshot = Persisted(
            totalSeconds: totalSeconds,
            totalWords: totalWords,
            totalSessions: totalSessions,
            installID: installID)
        try? snapshot.save(to: storeURL)
    }

    // MARK: On-disk shape

    /// Every field optional so adding new counters never fails to decode an old
    /// file (forward/backward compatible), matching `AppSettings.Persisted`.
    struct Persisted: Codable {
        var totalSeconds: Double?
        var totalWords: Int?
        var totalSessions: Int?
        var installID: String?

        static func load(from url: URL) throws -> Persisted {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Persisted.self, from: data)
        }

        func save(to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
        }
    }
}
