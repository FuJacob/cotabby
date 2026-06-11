import Foundation

/// File overview:
/// Pure date-bucketing and aggregation rules for usage analytics (issue #489), split out from
/// `UsageAnalyticsStore` so the counting math is unit-testable without `UserDefaults` or the main
/// actor. Every entry point takes its `calendar` and reference `now` explicitly: tests pin them to a
/// fixed gregorian/UTC calendar and fixed dates, while production passes `.current` and `Date()`.
enum UsageAnalyticsAggregator {
    /// Start of the calendar day containing `date`. This is the bucket key, so two accepts on the
    /// same local day fold into one bucket regardless of wall-clock time.
    static func dayStart(for date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    /// Folds one acceptance into `buckets`, returning the updated, day-sorted array. Adds to the
    /// existing bucket for `date`'s day when present, otherwise inserts a new one. Word/character
    /// counts are clamped non-negative so a malformed persisted blob can never drag a total below
    /// zero.
    static func recording(
        words: Int,
        characters: Int,
        on date: Date,
        into buckets: [UsageAnalyticsDailyBucket],
        calendar: Calendar
    ) -> [UsageAnalyticsDailyBucket] {
        let key = dayStart(for: date, calendar: calendar)
        let addedWords = max(0, words)
        let addedCharacters = max(0, characters)

        var updated = buckets
        if let index = updated.firstIndex(where: { $0.day == key }) {
            updated[index].acceptances += 1
            updated[index].words += addedWords
            updated[index].characters += addedCharacters
            return updated
        }

        updated.append(
            UsageAnalyticsDailyBucket(
                day: key,
                acceptances: 1,
                words: addedWords,
                characters: addedCharacters
            )
        )
        updated.sort { $0.day < $1.day }
        return updated
    }

    /// Sums the buckets that fall within `range` relative to `now`. `.allTime` includes everything;
    /// a windowed range includes the bucket for today plus the previous `dayWindow - 1` days.
    static func totals(
        in buckets: [UsageAnalyticsDailyBucket],
        range: UsageAnalyticsRange,
        now: Date,
        calendar: Calendar
    ) -> UsageAnalyticsTotals {
        let included: [UsageAnalyticsDailyBucket]
        if let window = range.dayWindow, let cutoff = cutoffDay(window: window, now: now, calendar: calendar) {
            included = buckets.filter { $0.day >= cutoff }
        } else {
            included = buckets
        }

        return included.reduce(into: .zero) { totals, bucket in
            totals.acceptances += bucket.acceptances
            totals.words += bucket.words
            totals.characters += bucket.characters
        }
    }

    /// A dense, day-sorted series for the last `days` calendar days ending today (oldest first), with
    /// any day that has no recorded activity filled in as a zero bucket. Drives the pane's bar chart
    /// so gaps render as empty bars instead of collapsing the axis.
    static func dailyBuckets(
        from buckets: [UsageAnalyticsDailyBucket],
        days: Int,
        now: Date,
        calendar: Calendar
    ) -> [UsageAnalyticsDailyBucket] {
        guard days > 0 else { return [] }
        let today = dayStart(for: now, calendar: calendar)
        let byDay = Dictionary(buckets.map { ($0.day, $0) }, uniquingKeysWith: { existing, _ in existing })

        var dense: [UsageAnalyticsDailyBucket] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            dense.append(
                byDay[day] ?? UsageAnalyticsDailyBucket(day: day, acceptances: 0, words: 0, characters: 0)
            )
        }
        return dense
    }

    /// First day included by a windowed range: today minus `window - 1` days, so the window counts
    /// today inclusively.
    private static func cutoffDay(window: Int, now: Date, calendar: Calendar) -> Date? {
        let today = dayStart(for: now, calendar: calendar)
        return calendar.date(byAdding: .day, value: -(max(1, window) - 1), to: today)
    }
}
