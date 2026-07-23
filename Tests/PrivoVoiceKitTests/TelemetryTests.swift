// Coverage for the usage/telemetry layer: local aggregate persistence, the
// playful equivalents picker, opt-in gating, and the settings round-trip for the
// telemetry toggle. No network is ever touched here.

import XCTest
import Foundation
@testable import PrivoVoiceKit

final class UsageStatsTests: XCTestCase {
    private func tempStore() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "voixful-usage-\(UUID().uuidString)/usage.json")
    }

    @MainActor
    func testStartsEmpty() {
        let s = UsageStats(storeURL: tempStore())
        XCTAssertEqual(s.totalSeconds, 0)
        XCTAssertEqual(s.totalWords, 0)
        XCTAssertEqual(s.totalSessions, 0)
        XCTAssertFalse(s.installID.isEmpty)
    }

    @MainActor
    func testRecordAccumulates() {
        let s = UsageStats(storeURL: tempStore())
        s.record(seconds: 12.5, words: 30)
        s.record(seconds: 7.5, words: 10)
        XCTAssertEqual(s.totalSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(s.totalWords, 40)
        XCTAssertEqual(s.totalSessions, 2)
    }

    @MainActor
    func testRecordClampsNegatives() {
        let s = UsageStats(storeURL: tempStore())
        s.record(seconds: -5, words: -3)
        XCTAssertEqual(s.totalSeconds, 0)
        XCTAssertEqual(s.totalWords, 0)
        XCTAssertEqual(s.totalSessions, 1)   // still counts the session
    }

    @MainActor
    func testPersistenceRoundTripAndStableInstallID() {
        let url = tempStore()
        let a = UsageStats(storeURL: url)
        a.record(seconds: 100, words: 250)
        let id = a.installID
        a.saveNow()

        let b = UsageStats(storeURL: url)
        XCTAssertEqual(b.totalSeconds, 100, accuracy: 0.001)
        XCTAssertEqual(b.totalWords, 250)
        XCTAssertEqual(b.totalSessions, 1)
        XCTAssertEqual(b.installID, id, "install ID must be stable across launches")
    }

    @MainActor
    func testResetKeepsInstallID() {
        let s = UsageStats(storeURL: tempStore())
        s.record(seconds: 10, words: 5)
        let id = s.installID
        s.reset()
        XCTAssertEqual(s.totalSeconds, 0)
        XCTAssertEqual(s.totalWords, 0)
        XCTAssertEqual(s.totalSessions, 0)
        XCTAssertEqual(s.installID, id)
    }
}

final class UsageEquivalentsTests: XCTestCase {
    func testNothingYet() {
        XCTAssertNil(UsageEquivalents.forDuration(seconds: 0))
        XCTAssertNil(UsageEquivalents.forWords(0))
    }

    func testPicksLargestSurpassedDurationAnchor() {
        // 4 hours has passed the movie Titanic (3h14m) but not LOTR (11h+).
        let e = UsageEquivalents.forDuration(seconds: 4 * 3600)
        XCTAssertEqual(e?.name, "the movie Titanic")
        XCTAssertGreaterThan(e?.multiple ?? 0, 1)
    }

    func testBelowSmallestDurationAnchorIsAFraction() {
        // 10s < the smallest anchor (a 30s voicemail): reported as a fraction.
        let e = UsageEquivalents.forDuration(seconds: 10)
        XCTAssertEqual(e?.name, "a voicemail")
        XCTAssertLessThan(e?.multiple ?? 99, 1)
    }

    func testHugeTotalLandsOnTopAnchor() {
        // Two years of talking exceeds every anchor → the largest one.
        let e = UsageEquivalents.forDuration(seconds: 2 * 365 * 24 * 3600)
        XCTAssertEqual(e?.name, "a solid year of talking")
        XCTAssertGreaterThan(e?.multiple ?? 0, 1)
    }

    func testWordsAnchorScales() {
        // 600k words is past War and Peace (587k) but shy of the full HP series.
        let e = UsageEquivalents.forWords(600_000)
        XCTAssertEqual(e?.name, "War and Peace")
    }

    func testMultipleFormatting() {
        XCTAssertEqual(UsageEquivalent.formatMultiple(1.0), "about")
        XCTAssertEqual(UsageEquivalent.formatMultiple(2.0), "2×")
        XCTAssertEqual(UsageEquivalent.formatMultiple(2.3), "2.3×")
        XCTAssertEqual(UsageEquivalent.formatMultiple(42), "42×")
    }

    func testFractionLabelsMatchTheirMagnitude() {
        XCTAssertEqual(UsageEquivalent.formatMultiple(0.05), "a sliver of")
        XCTAssertEqual(UsageEquivalent.formatMultiple(0.33), "a third of")
        XCTAssertEqual(UsageEquivalent.formatMultiple(0.5), "half of")   // not "a third of"
        XCTAssertEqual(UsageEquivalent.formatMultiple(0.85), "most of")
    }
}

/// Captures events instead of sending them, so a test can assert exactly when
/// (and what) the recording path emits. `@unchecked Sendable` is safe here: it's
/// only ever touched on the main actor in these tests.
private final class SpyReporter: TelemetryReporting, @unchecked Sendable {
    var sent: [TelemetryEvent] = []
    func send(_ event: TelemetryEvent) { sent.append(event) }
}

final class TelemetryGatingTests: XCTestCase {
    @MainActor
    private func tempSettings() -> AppSettings {
        AppSettings(storeURL: FileManager.default.temporaryDirectory
            .appending(path: "voixful-tele-\(UUID().uuidString)/settings.json"))
    }

    @MainActor
    func testTelemetryDefaultsOff() {
        XCTAssertFalse(tempSettings().telemetryEnabled)
    }

    @MainActor
    func testTelemetryToggleRoundTrips() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "voixful-tele-\(UUID().uuidString)/settings.json")
        let a = AppSettings(storeURL: url)
        a.telemetryEnabled = true
        a.saveNow()
        XCTAssertTrue(AppSettings(storeURL: url).telemetryEnabled)
    }

    @MainActor
    func testRecordAlwaysUpdatesLocalStatsRegardlessOfOptIn() {
        // Opted OUT: local Dashboard stats must still update; no report is sent
        // (the reporter's default endpoint is never hit because send() is gated).
        let settings = tempSettings()
        settings.telemetryEnabled = false
        let stats = UsageStats(storeURL: FileManager.default.temporaryDirectory
            .appending(path: "voixful-usage-\(UUID().uuidString)/usage.json"))
        let telemetry = Telemetry(settings: settings, stats: stats)

        telemetry.record(seconds: 30, words: 60, modelID: nil)
        XCTAssertEqual(stats.totalSessions, 1)
        XCTAssertEqual(stats.totalWords, 60)
        XCTAssertEqual(stats.totalSeconds, 30, accuracy: 0.001)
    }

    @MainActor
    private func makeTelemetry(enabled: Bool) -> (Telemetry, SpyReporter, UsageStats) {
        let settings = tempSettings()
        settings.telemetryEnabled = enabled
        let stats = UsageStats(storeURL: FileManager.default.temporaryDirectory
            .appending(path: "voixful-usage-\(UUID().uuidString)/usage.json"))
        let spy = SpyReporter()
        return (Telemetry(settings: settings, stats: stats, reporter: spy), spy, stats)
    }

    @MainActor
    func testOptedOutSendsNothing() {
        let (telemetry, spy, _) = makeTelemetry(enabled: false)
        telemetry.record(seconds: 30, words: 60, modelID: "parakeet-tdt-0.6b-v2")
        XCTAssertTrue(spy.sent.isEmpty, "opted-out must never hit the reporter")
    }

    @MainActor
    func testOptedInSendsOneEventWithTheSessionData() throws {
        let (telemetry, spy, _) = makeTelemetry(enabled: true)
        telemetry.record(seconds: 30, words: 60, modelID: "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(spy.sent.count, 1)
        let event = try XCTUnwrap(spy.sent.first)
        XCTAssertEqual(event.sessionSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(event.sessionWords, 60)
        XCTAssertEqual(event.modelID, "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(event.totalSessions, 1)   // running totals ride along
    }

    /// The privacy contract, enforced structurally: the encoded payload must
    /// carry only counts + coarse metadata — never a transcript/text/audio field.
    /// Guards against a future field being added by accident.
    func testPayloadCarriesNoTranscriptOrAudio() throws {
        let event = TelemetryEvent(
            installID: "id", appVersion: "PrivoVoice 0.1.0", osVersion: "macOS",
            modelID: "m", sessionSeconds: 1, sessionWords: 2,
            totalSeconds: 3, totalWords: 4, totalSessions: 5)
        let data = try JSONEncoder().encode(event)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys = Set(object?.keys ?? [:].keys)
        XCTAssertEqual(keys, [
            "installID", "appVersion", "osVersion", "modelID",
            "sessionSeconds", "sessionWords",
            "totalSeconds", "totalWords", "totalSessions",
        ], "payload key set changed — verify no transcript/audio content leaked in")
        for banned in ["transcript", "text", "audio", "words_text", "content", "samples"] {
            XCTAssertFalse(keys.contains(banned), "payload must not include '\(banned)'")
        }
    }
}

final class WordCountTests: XCTestCase {
    func testWordCount() {
        XCTAssertEqual(DictationController.wordCount(""), 0)
        XCTAssertEqual(DictationController.wordCount("   "), 0)
        XCTAssertEqual(DictationController.wordCount("hello"), 1)
        XCTAssertEqual(DictationController.wordCount("  hello   world  "), 2)
        XCTAssertEqual(DictationController.wordCount("one two\nthree\tfour"), 4)
    }
}
