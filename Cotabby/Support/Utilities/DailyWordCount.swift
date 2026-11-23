import Foundation

/// File overview:
/// The accepted-word count for one local calendar day, which is what the menu-bar badge shows.
/// The lifetime total keeps growing forever, so a badge fed from it only ever climbs; this value
/// starts again from zero each day.
///
/// It is its own pure value, rather than a pair of loose integers on `SuggestionCoordinator`,
/// because "which day does this count belong to" is a rule with an edge worth testing on its own:
/// a count stored yesterday must read as zero today, whether the day turned while the app was
/// running, asleep, or quit. The coordinator owns one instance, persists its two fields in
/// UserDefaults, and asks it to roll forward before every read or write.
nonisolated struct DailyWordCount: Equatable {
    /// The local day the count belongs to, as `yyyy-MM-dd`. A stamp rather than a `Date` so the
    /// comparison is exact and the stored value is readable in `defaults read`.
    private(set) var dayStamp: String
    private(set) var count: Int

    init(dayStamp: String, count: Int) {
        self.dayStamp = dayStamp
        self.count = max(count, 0)
    }

    /// The same count if `date` falls on its day, otherwise a fresh zero for `date`'s day. Any
    /// different stamp resets, not only a later one, so a clock or time-zone change that moves the
    /// day backwards cannot leave a count stranded on a day that never comes round again.
    func rolled(to date: Date, calendar: Calendar = .current) -> DailyWordCount {
        let today = Self.dayStamp(for: date, calendar: calendar)
        return today == dayStamp ? self : DailyWordCount(dayStamp: today, count: 0)
    }

    /// Adds words accepted at `date`, rolling to that day first.
    func adding(_ words: Int, at date: Date, calendar: Calendar = .current) -> DailyWordCount {
        var rolled = rolled(to: date, calendar: calendar)
        rolled.count += max(words, 0)
        return rolled
    }

    /// Built from calendar components instead of a `DateFormatter` so the stamp never depends on
    /// the user's locale or calendar-format preferences.
    static func dayStamp(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
