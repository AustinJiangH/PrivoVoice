// The seam between the dictation pipeline and everything usage-related.
//
// `DictationController` calls `record(...)` once per completed dictation and
// knows nothing else. This class does two things with that call:
//   1. Always folds it into the LOCAL `UsageStats` (what the Dashboard shows).
//   2. Emits an opt-in network report — ONLY when the user has enabled it.
// Recording is best-effort and never throws, so the dictation path is untouched
// whether telemetry is on, off, or the network is down.

import Foundation
import Observation

@MainActor
@Observable
public final class Telemetry {
    /// Local, always-updated totals for the Dashboard.
    public let stats: UsageStats
    /// Local, always-updated per-dictation history that powers the usage charts.
    public let log: DictationLog

    private let settings: AppSettings
    private let reporter: any TelemetryReporting

    public init(
        settings: AppSettings,
        stats: UsageStats = UsageStats(),
        log: DictationLog = DictationLog(),
        reporter: any TelemetryReporting = TelemetryReporter()
    ) {
        self.settings = settings
        self.stats = stats
        self.log = log
        self.reporter = reporter
    }

    /// Record one completed dictation. Local totals always update; a network
    /// report goes out only when `settings.telemetryEnabled` is true. Both are
    /// best-effort — this method cannot fail in a way the caller can observe.
    public func record(seconds: Double, words: Int, modelID: String?) {
        stats.record(seconds: seconds, words: words)
        // Local per-dictation history for the charts — always on, like `stats`.
        log.record(seconds: seconds, words: words, modelID: modelID, date: Date())

        guard settings.telemetryEnabled else { return }
        let event = TelemetryEvent(
            installID: stats.installID,
            appVersion: "\(AppInfo.name) \(AppInfo.version)",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            modelID: modelID,
            sessionSeconds: seconds,
            sessionWords: words,
            totalSeconds: stats.totalSeconds,
            totalWords: stats.totalWords,
            totalSessions: stats.totalSessions)
        reporter.send(event)
    }
}
