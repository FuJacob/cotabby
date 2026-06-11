import XCTest
@testable import Cotabby

/// Pure tests for usage-analytics date bucketing and range math (issue #489). No store, no
/// UserDefaults, no main actor: just `UsageAnalyticsAggregator` against a fixed gregorian/UTC
/// calendar and pinned dates, so day boundaries are deterministic regardless of the host's locale or
/// timezone.
final class UsageAnalyticsAggregatorTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    // MARK: - dayStart

    func test_dayStart_collapsesTimeOfDayToOneKey() {
        let morning = date(2026, 3, 14, 8)
        let evening = date(2026, 3, 14, 23)
        XCTAssertEqual(
            UsageAnalyticsAggregator.dayStart(for: morning, calendar: calendar),
            UsageAnalyticsAggregator.dayStart(for: evening, calendar: calendar)
        )
    }

    // MARK: - recording

    func test_recording_mergesAcceptsOnTheSameDay() {
        var buckets: [UsageAnalyticsDailyBucket] = []
        buckets = record(2, 9, on: date(2026, 3, 14, 9), into: buckets)
        buckets = record(3, 11, on: date(2026, 3, 14, 20), into: buckets)

        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].acceptances, 2)
        XCTAssertEqual(buckets[0].words, 5)
        XCTAssertEqual(buckets[0].characters, 20)
    }

    func test_recording_keepsDistinctDaysSortedOldestFirst() {
        var buckets: [UsageAnalyticsDailyBucket] = []
        buckets = record(1, 4, on: date(2026, 3, 14), into: buckets)
        buckets = record(1, 4, on: date(2026, 3, 12), into: buckets)
        buckets = record(1, 4, on: date(2026, 3, 13), into: buckets)

        XCTAssertEqual(buckets.map { calendar.component(.day, from: $0.day) }, [12, 13, 14])
    }

    func test_recording_clampsNegativeCountsButStillCountsTheAcceptance() {
        let buckets = record(-5, -2, on: date(2026, 3, 14), into: [])
        XCTAssertEqual(buckets[0].words, 0)
        XCTAssertEqual(buckets[0].characters, 0)
        XCTAssertEqual(buckets[0].acceptances, 1)
    }

    // MARK: - totals

    func test_totals_allTimeSumsEveryBucket() {
        let totals = UsageAnalyticsAggregator.totals(
            in: sampleBuckets(),
            range: .allTime,
            now: date(2026, 3, 31),
            calendar: calendar
        )
        XCTAssertEqual(totals.acceptances, 3)
        XCTAssertEqual(totals.words, 10)
        XCTAssertEqual(totals.characters, 40)
    }

    func test_totals_last7DaysIncludesTodayAndPreviousSixOnly() {
        let buckets = [
            bucket(2026, 3, 24, words: 100),
            bucket(2026, 3, 25, words: 1),
            bucket(2026, 3, 31, words: 2)
        ]
        let totals = UsageAnalyticsAggregator.totals(
            in: buckets,
            range: .last7Days,
            now: date(2026, 3, 31),
            calendar: calendar
        )
        // Mar 25...Mar 31 inclusive, so Mar 24 falls outside the window.
        XCTAssertEqual(totals.words, 3)
    }

    func test_totals_last30DaysExcludesDaysBeforeTheWindow() {
        let buckets = [
            bucket(2026, 3, 1, words: 5),
            bucket(2026, 3, 2, words: 7),
            bucket(2026, 3, 31, words: 2)
        ]
        let totals = UsageAnalyticsAggregator.totals(
            in: buckets,
            range: .last30Days,
            now: date(2026, 3, 31),
            calendar: calendar
        )
        // 30-day window ending Mar 31 starts Mar 2, so Mar 1 is excluded.
        XCTAssertEqual(totals.words, 9)
    }

    func test_totals_emptyBucketsAreZero() {
        let totals = UsageAnalyticsAggregator.totals(
            in: [],
            range: .allTime,
            now: date(2026, 3, 31),
            calendar: calendar
        )
        XCTAssertEqual(totals, .zero)
    }

    // MARK: - dailyBuckets

    func test_dailyBuckets_isDenseZeroFilledOldestFirst() {
        let series = UsageAnalyticsAggregator.dailyBuckets(
            from: [bucket(2026, 3, 31, words: 4)],
            days: 7,
            now: date(2026, 3, 31),
            calendar: calendar
        )
        XCTAssertEqual(series.count, 7)
        XCTAssertEqual(calendar.component(.day, from: series.first!.day), 25)
        XCTAssertEqual(series.last?.words, 4)
        XCTAssertEqual(series.dropLast().reduce(0) { $0 + $1.words }, 0)
    }

    func test_dailyBuckets_zeroDaysIsEmpty() {
        let series = UsageAnalyticsAggregator.dailyBuckets(
            from: sampleBuckets(),
            days: 0,
            now: date(2026, 3, 31),
            calendar: calendar
        )
        XCTAssertTrue(series.isEmpty)
    }

    // MARK: - Helpers

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return calendar.date(from: components)!
    }

    private func record(
        _ words: Int,
        _ characters: Int,
        on date: Date,
        into buckets: [UsageAnalyticsDailyBucket]
    ) -> [UsageAnalyticsDailyBucket] {
        UsageAnalyticsAggregator.recording(
            words: words,
            characters: characters,
            on: date,
            into: buckets,
            calendar: calendar
        )
    }

    private func bucket(_ year: Int, _ month: Int, _ day: Int, words: Int) -> UsageAnalyticsDailyBucket {
        UsageAnalyticsDailyBucket(
            day: UsageAnalyticsAggregator.dayStart(for: date(year, month, day), calendar: calendar),
            acceptances: 1,
            words: words,
            characters: words * 4
        )
    }

    private func sampleBuckets() -> [UsageAnalyticsDailyBucket] {
        [
            bucket(2026, 3, 10, words: 3),
            bucket(2026, 3, 20, words: 5),
            bucket(2026, 3, 30, words: 2)
        ]
    }
}
