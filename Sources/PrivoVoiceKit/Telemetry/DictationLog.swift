// Per-dictation history that powers the Dashboard's usage charts.
//
// Where `UsageStats` keeps running TOTALS, this keeps one row per completed
// dictation so we can chart usage over time, by hour of day, and by model.
// Everything is computed and stored LOCALLY — it never leaves the Mac. Persisted
// as JSON next to settings, following the same debounced-save pattern as
// `UsageStats`, and kept in PrivoVoiceKit so a future iOS app reuses it.

import Foundation
import Observation

/// One completed dictation. Backend / display name are intentionally NOT stored
/// — they're derived at read time from `ModelCatalog` so the log stays a compact,
/// stable record even as catalog metadata evolves.
public struct DictationRecord: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let date: Date
    public let modelID: String?
    public let seconds: Double
    public let words: Int

    public init(id: UUID = UUID(), date: Date, modelID: String?, seconds: Double, words: Int) {
        self.id = id
        self.date = date
        self.modelID = modelID
        self.seconds = seconds
        self.words = words
    }
}

/// Seconds/words/count for a single calendar day.
public struct DayBucket: Sendable, Hashable, Identifiable {
    public let day: Date
    public let seconds: Double
    public let words: Int
    public let count: Int
    public var id: Date { day }
}

/// Seconds/count for one hour slot (0…23) of the day.
public struct HourBucket: Sendable, Hashable, Identifiable {
    public let hour: Int
    public let seconds: Double
    public let count: Int
    public var id: Int { hour }
}

/// Totals grouped by model, with the display name resolved for the axis.
public struct ModelBucket: Sendable, Hashable, Identifiable {
    public let modelID: String?
    public let displayName: String
    public let seconds: Double
    public let words: Int
    public let count: Int
    public var id: String { modelID ?? "__unknown__" }
}

@MainActor
@Observable
public final class DictationLog {
    /// Every completed dictation, oldest → newest.
    public private(set) var records: [DictationRecord]

    /// Keep the file bounded: retain at most this many most-recent rows.
    static let softCap = 20_000

    private var saveScheduled = false
    private let storeURL: URL

    /// `~/Library/Application Support/PrivoVoice/dictations.json`.
    public static var defaultStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base.appending(path: "PrivoVoice/dictations.json")
    }

    // MARK: Init / persistence

    public init(storeURL: URL = DictationLog.defaultStoreURL) {
        self.storeURL = storeURL
        if let persisted = try? Persisted.load(from: storeURL) {
            self.records = persisted.records ?? []
        } else {
            self.records = []
        }
    }

    // MARK: Mutation

    /// Append one completed dictation. Negatives are clamped to zero so a bad
    /// measurement can never corrupt the history. Best-effort and never throws —
    /// recording must never affect the transcription flow.
    public func record(seconds: Double, words: Int, modelID: String?, date: Date = Date()) {
        let entry = DictationRecord(
            date: date, modelID: modelID,
            seconds: max(0, seconds), words: max(0, words))
        records.append(entry)
        if records.count > Self.softCap {
            records.removeFirst(records.count - Self.softCap)
        }
        scheduleSave()
    }

    /// Wipe the local history.
    public func reset() {
        records = []
        saveNow()
    }

    // MARK: Aggregation (pure, value-typed — unit-testable without SwiftUI)

    /// One bucket per calendar day for the last `days` days (including empty
    /// days), ascending. Buckets sum seconds/words and count dictations.
    public func dailyTotals(days: Int, calendar: Calendar = .current, now: Date = Date()) -> [DayBucket] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        // Pre-seed one bucket per day so empty days still appear.
        var totals: [Date: (seconds: Double, words: Int, count: Int)] = [:]
        var dayStarts: [Date] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            dayStarts.append(day)
            totals[day] = (0, 0, 0)
        }
        guard let earliest = dayStarts.first else { return [] }
        for r in records where r.date >= earliest {
            let day = calendar.startOfDay(for: r.date)
            guard var acc = totals[day] else { continue }   // outside the window (future)
            acc.seconds += r.seconds
            acc.words += r.words
            acc.count += 1
            totals[day] = acc
        }
        return dayStarts.map { day in
            let acc = totals[day] ?? (0, 0, 0)
            return DayBucket(day: day, seconds: acc.seconds, words: acc.words, count: acc.count)
        }
    }

    /// 24 buckets (0…23) describing when-of-day you dictate.
    public func hourlyDistribution(calendar: Calendar = .current) -> [HourBucket] {
        var seconds = [Double](repeating: 0, count: 24)
        var counts = [Int](repeating: 0, count: 24)
        for r in records {
            let hour = calendar.component(.hour, from: r.date)
            guard (0..<24).contains(hour) else { continue }
            seconds[hour] += r.seconds
            counts[hour] += 1
        }
        return (0..<24).map { HourBucket(hour: $0, seconds: seconds[$0], count: counts[$0]) }
    }

    /// Totals grouped by `modelID`, display name resolved via the catalog,
    /// sorted by seconds descending.
    public func modelTotals() -> [ModelBucket] {
        struct Acc { var seconds = 0.0; var words = 0; var count = 0 }
        var groups: [String?: Acc] = [:]
        for r in records {
            var acc = groups[r.modelID] ?? Acc()
            acc.seconds += r.seconds
            acc.words += r.words
            acc.count += 1
            groups[r.modelID] = acc
        }
        return groups.map { modelID, acc in
            let name = modelID.flatMap { ModelCatalog.spec(id: $0)?.displayName } ?? "Unknown"
            return ModelBucket(
                modelID: modelID, displayName: name,
                seconds: acc.seconds, words: acc.words, count: acc.count)
        }
        .sorted { $0.seconds > $1.seconds }
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
        let snapshot = Persisted(records: records)
        try? snapshot.save(to: storeURL)
    }

    // MARK: On-disk shape

    /// Every field optional so adding new counters never fails to decode an old
    /// file (forward/backward compatible), matching `UsageStats.Persisted`.
    struct Persisted: Codable {
        var records: [DictationRecord]?

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
