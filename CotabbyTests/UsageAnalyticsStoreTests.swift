import XCTest
@testable import Cotabby

/// Tests for `UsageAnalyticsStore`: recording, range totals, persistence across instances, and reset
/// (issue #489). Uses an in-memory defaults stand-in and a fixed gregorian/UTC calendar so day
/// bucketing is deterministic. The class is intentionally NOT `@MainActor` (an isolated XCTest
/// subclass crashes the app-hosted runner), so each body hops onto the main actor via
/// `runOnMainActor`.
final class UsageAnalyticsStoreTests: XCTestCase {
    private final class InMemoryDefaults: UsageAnalyticsDefaults {
        private var storage: [String: Data] = [:]
        func data(forKey defaultName: String) -> Data? { storage[defaultName] }
        func set(_ value: Any?, forKey defaultName: String) { storage[defaultName] = value as? Data }
        func removeObject(forKey defaultName: String) { storage[defaultName] = nil }
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func test_recordAcceptance_accumulatesAllTimeTotals() {
        runOnMainActor {
            let store = UsageAnalyticsStore(defaults: InMemoryDefaults(), calendar: Self.utcCalendar)
            store.recordAcceptance(words: 2, characters: 10, date: Self.date(2026, 3, 14))
            store.recordAcceptance(words: 3, characters: 12, date: Self.date(2026, 3, 14))

            let totals = store.totals(in: .allTime, now: Self.date(2026, 3, 14))
            XCTAssertEqual(totals.acceptances, 2)
            XCTAssertEqual(totals.words, 5)
            XCTAssertEqual(totals.characters, 22)
        }
    }

    func test_recordAcceptance_ignoresFullyEmptyAccept() {
        runOnMainActor {
            let store = UsageAnalyticsStore(defaults: InMemoryDefaults(), calendar: Self.utcCalendar)
            store.recordAcceptance(words: 0, characters: 0, date: Self.date(2026, 3, 14))
            XCTAssertTrue(store.buckets.isEmpty)
        }
    }

    func test_rangeTotals_respectTheSevenDayWindow() {
        runOnMainActor {
            let store = UsageAnalyticsStore(defaults: InMemoryDefaults(), calendar: Self.utcCalendar)
            store.recordAcceptance(words: 9, characters: 9, date: Self.date(2026, 3, 1))
            store.recordAcceptance(words: 4, characters: 4, date: Self.date(2026, 3, 28))

            let now = Self.date(2026, 3, 31)
            XCTAssertEqual(store.totals(in: .last7Days, now: now).words, 4)
            XCTAssertEqual(store.totals(in: .allTime, now: now).words, 13)
        }
    }

    func test_statePersistsAcrossInstances() {
        runOnMainActor {
            let defaults = InMemoryDefaults()
            UsageAnalyticsStore(defaults: defaults, calendar: Self.utcCalendar)
                .recordAcceptance(words: 7, characters: 30, date: Self.date(2026, 3, 14))

            let reopened = UsageAnalyticsStore(defaults: defaults, calendar: Self.utcCalendar)
            let totals = reopened.totals(in: .allTime, now: Self.date(2026, 3, 14))
            XCTAssertEqual(totals.acceptances, 1)
            XCTAssertEqual(totals.words, 7)
            XCTAssertEqual(totals.characters, 30)
        }
    }

    func test_clearForgetsEverythingAndRemovesPersistedBlob() {
        runOnMainActor {
            let defaults = InMemoryDefaults()
            let store = UsageAnalyticsStore(defaults: defaults, calendar: Self.utcCalendar)
            store.recordAcceptance(words: 1, characters: 5, date: Self.date(2026, 3, 14))
            store.clear()

            XCTAssertTrue(store.buckets.isEmpty)
            let reopened = UsageAnalyticsStore(defaults: defaults, calendar: Self.utcCalendar)
            XCTAssertTrue(reopened.buckets.isEmpty)
        }
    }

    func test_recentDailyBuckets_isDenseAndOldestFirst() {
        runOnMainActor {
            let store = UsageAnalyticsStore(defaults: InMemoryDefaults(), calendar: Self.utcCalendar)
            store.recordAcceptance(words: 6, characters: 24, date: Self.date(2026, 3, 31))

            let series = store.recentDailyBuckets(days: 7, now: Self.date(2026, 3, 31))
            XCTAssertEqual(series.count, 7)
            XCTAssertEqual(series.last?.words, 6)
            XCTAssertEqual(series.dropLast().reduce(0) { $0 + $1.words }, 0)
        }
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return utcCalendar.date(from: components)!
    }
}

private func runOnMainActor<Result>(
    _ body: @MainActor () throws -> Result
) rethrows -> Result {
    if Thread.isMainThread {
        return try MainActor.assumeIsolated(body)
    }
    return try DispatchQueue.main.sync {
        try MainActor.assumeIsolated(body)
    }
}
