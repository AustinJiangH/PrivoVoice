// Coverage for the per-dictation history that powers the Dashboard charts:
// appends + clamping, the soft cap, the pure aggregation helpers, reset, and
// round-trip persistence. Everything is LOCAL — no network is ever touched here.

import XCTest
import Foundation
@testable import PrivoVoiceKit

final class DictationLogTests: XCTestCase {
    private func tempStore() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "voixful-dictations-\(UUID().uuidString)/dictations.json")
    }

    // MARK: record / clamp

    @MainActor
    func testRecordAppends() {
        let log = DictationLog(storeURL: tempStore())
        log.record(seconds: 12.5, words: 30, modelID: "parakeet-tdt-0.6b-v2")
        log.record(seconds: 7.5, words: 10, modelID: nil)
        XCTAssertEqual(log.records.count, 2)
        XCTAssertEqual(log.records[0].seconds, 12.5, accuracy: 0.001)
        XCTAssertEqual(log.records[0].words, 30)
        XCTAssertEqual(log.records[0].modelID, "parakeet-tdt-0.6b-v2")
        XCTAssertNil(log.records[1].modelID)
    }

    @MainActor
    func testRecordClampsNegatives() {
        let log = DictationLog(storeURL: tempStore())
        log.record(seconds: -5, words: -3, modelID: nil)
        XCTAssertEqual(log.records.count, 1)
        XCTAssertEqual(log.records[0].seconds, 0)
        XCTAssertEqual(log.records[0].words, 0)
    }

    @MainActor
    func testSoftCapDropsOldest() {
        let log = DictationLog(storeURL: tempStore())
        let cap = DictationLog.softCap
        // One past the cap: the very first (words == 0) must fall off.
        for i in 0...cap {
            log.record(seconds: 1, words: i, modelID: nil)
        }
        XCTAssertEqual(log.records.count, cap)
        XCTAssertEqual(log.records.first?.words, 1, "oldest (words == 0) should be dropped")
        XCTAssertEqual(log.records.last?.words, cap)
    }

    // MARK: dailyTotals

    @MainActor
    func testDailyTotalsBucketsIncludingEmptyDays() {
        let log = DictationLog(storeURL: tempStore())
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)   // fixed reference
        let today = cal.startOfDay(for: now)
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: today)!

        // Two records today, one two days ago, one day (yesterday) left empty.
        log.record(seconds: 10, words: 5, modelID: nil, date: today.addingTimeInterval(3600))
        log.record(seconds: 20, words: 7, modelID: nil, date: today.addingTimeInterval(7200))
        log.record(seconds: 30, words: 9, modelID: nil, date: twoDaysAgo.addingTimeInterval(60))

        let buckets = log.dailyTotals(days: 3, calendar: cal, now: now)
        XCTAssertEqual(buckets.count, 3)
        // Ascending: [twoDaysAgo, yesterday(empty), today]
        XCTAssertEqual(buckets[0].seconds, 30, accuracy: 0.001)
        XCTAssertEqual(buckets[0].words, 9)
        XCTAssertEqual(buckets[0].count, 1)
        XCTAssertEqual(buckets[1].count, 0, "yesterday has no dictations")
        XCTAssertEqual(buckets[1].seconds, 0)
        XCTAssertEqual(buckets[2].seconds, 30, accuracy: 0.001)
        XCTAssertEqual(buckets[2].words, 12)
        XCTAssertEqual(buckets[2].count, 2)
        // Buckets must be strictly ascending by day.
        XCTAssertTrue(buckets[0].day < buckets[1].day && buckets[1].day < buckets[2].day)
    }

    @MainActor
    func testDailyTotalsExcludesRecordsOutsideWindow() {
        let log = DictationLog(storeURL: tempStore())
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let today = cal.startOfDay(for: now)
        let tenDaysAgo = cal.date(byAdding: .day, value: -10, to: today)!

        log.record(seconds: 99, words: 99, modelID: nil, date: tenDaysAgo)
        let buckets = log.dailyTotals(days: 3, calendar: cal, now: now)
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.count }, 0, "old record is outside the 3-day window")
    }

    // MARK: hourlyDistribution

    @MainActor
    func testHourlyDistributionReturns24BucketsKeyedByHour() {
        let log = DictationLog(storeURL: tempStore())
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let base = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        // Two dictations at 09:00, one at 14:00.
        log.record(seconds: 5, words: 1, modelID: nil, date: base.addingTimeInterval(9 * 3600))
        log.record(seconds: 6, words: 1, modelID: nil, date: base.addingTimeInterval(9 * 3600 + 120))
        log.record(seconds: 7, words: 1, modelID: nil, date: base.addingTimeInterval(14 * 3600))

        let buckets = log.hourlyDistribution(calendar: cal)
        XCTAssertEqual(buckets.count, 24)
        XCTAssertEqual(buckets.map(\.hour), Array(0..<24))
        XCTAssertEqual(buckets[9].count, 2)
        XCTAssertEqual(buckets[9].seconds, 11, accuracy: 0.001)
        XCTAssertEqual(buckets[14].count, 1)
        XCTAssertEqual(buckets[0].count, 0)
    }

    // MARK: modelTotals

    @MainActor
    func testModelTotalsGroupsResolvesNamesAndSortsDesc() {
        let log = DictationLog(storeURL: tempStore())
        // parakeet: 100s total across 2; nemotron: 250s; unknown id: 40s.
        log.record(seconds: 60, words: 10, modelID: "parakeet-tdt-0.6b-v2")
        log.record(seconds: 40, words: 5, modelID: "parakeet-tdt-0.6b-v2")
        log.record(seconds: 250, words: 90, modelID: "nemotron-speech-streaming-en-0.6b")
        log.record(seconds: 40, words: 3, modelID: "does-not-exist")

        let buckets = log.modelTotals()
        XCTAssertEqual(buckets.count, 3)
        // Sorted by seconds desc: nemotron (250), parakeet (100), unknown (40).
        XCTAssertEqual(buckets[0].modelID, "nemotron-speech-streaming-en-0.6b")
        XCTAssertEqual(buckets[0].displayName, "Nemotron Streaming")
        XCTAssertEqual(buckets[0].seconds, 250, accuracy: 0.001)
        XCTAssertEqual(buckets[1].modelID, "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(buckets[1].displayName, "Parakeet TDT v2")
        XCTAssertEqual(buckets[1].seconds, 100, accuracy: 0.001)
        XCTAssertEqual(buckets[1].count, 2)
        XCTAssertEqual(buckets[1].words, 15)
        XCTAssertEqual(buckets[2].displayName, "Unknown", "unknown id resolves to Unknown")
    }

    @MainActor
    func testModelTotalsNilModelIDResolvesToUnknown() {
        let log = DictationLog(storeURL: tempStore())
        log.record(seconds: 10, words: 1, modelID: nil)
        let buckets = log.modelTotals()
        XCTAssertEqual(buckets.count, 1)
        XCTAssertNil(buckets[0].modelID)
        XCTAssertEqual(buckets[0].displayName, "Unknown")
    }

    // MARK: reset

    @MainActor
    func testResetClears() {
        let log = DictationLog(storeURL: tempStore())
        log.record(seconds: 10, words: 5, modelID: nil)
        log.reset()
        XCTAssertTrue(log.records.isEmpty)
    }

    // MARK: persistence

    @MainActor
    func testPersistenceRoundTrip() {
        let url = tempStore()
        let a = DictationLog(storeURL: url)
        a.record(seconds: 100, words: 250, modelID: "parakeet-tdt-0.6b-v2",
                 date: Date(timeIntervalSince1970: 1_700_000_000))
        a.record(seconds: 5, words: 2, modelID: nil)
        a.saveNow()

        let b = DictationLog(storeURL: url)
        XCTAssertEqual(b.records.count, 2)
        XCTAssertEqual(b.records[0].seconds, 100, accuracy: 0.001)
        XCTAssertEqual(b.records[0].words, 250)
        XCTAssertEqual(b.records[0].modelID, "parakeet-tdt-0.6b-v2")
        XCTAssertNil(b.records[1].modelID)
    }

    @MainActor
    func testResetPersists() {
        let url = tempStore()
        let a = DictationLog(storeURL: url)
        a.record(seconds: 10, words: 5, modelID: nil)
        a.saveNow()
        a.reset()

        let b = DictationLog(storeURL: url)
        XCTAssertTrue(b.records.isEmpty, "reset should persist an empty history")
    }
}
