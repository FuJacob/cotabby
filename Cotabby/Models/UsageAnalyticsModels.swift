import Foundation

/// File overview:
/// Value types for the local usage-analytics feature (issue #489). These are the entire data model
/// the Usage settings pane and `UsageAnalyticsStore` share: aggregated per-day tallies, a totals
/// roll-up, and the time ranges the pane can show. They are pure value types so the bucketing math in
/// `UsageAnalyticsAggregator` stays trivially testable.

/// One calendar day's accepted-suggestion tallies. `day` is the start of that day (the bucket key) in
/// the calendar that recorded it; the counters are cumulative for the day.
///
/// This struct is the *complete* persisted analytics surface. No accepted text, prompt, OCR,
/// screenshot, app identity, or timestamp finer than the day is ever stored, which is what keeps the
/// feature local usage stats rather than telemetry.
struct UsageAnalyticsDailyBucket: Codable, Equatable, Identifiable, Sendable {
    /// Start of the calendar day this bucket aggregates. Doubles as the stable identity, since the
    /// aggregator guarantees at most one bucket per day.
    var day: Date
    /// Number of accepted suggestion chunks committed on this day (one per accept gesture).
    var acceptances: Int
    /// Word-like tokens across those accepted chunks, counted the same way as the menu-bar total.
    var words: Int
    /// Characters across those accepted chunks (grapheme count of the accepted text).
    var characters: Int

    var id: Date { day }
}

/// A roll-up of bucket counters across some time range: the three numbers the pane renders.
struct UsageAnalyticsTotals: Equatable, Sendable {
    var acceptances: Int
    var words: Int
    var characters: Int

    static let zero = UsageAnalyticsTotals(acceptances: 0, words: 0, characters: 0)
}

/// The windows the Usage pane can summarize. `dayWindow` is the inclusive number of calendar days
/// back from today (so `.last7Days` is today plus the previous six), or `nil` for all recorded
/// history.
enum UsageAnalyticsRange: String, CaseIterable, Identifiable, Sendable {
    case last7Days
    case last30Days
    case allTime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .last7Days: return "Last 7 Days"
        case .last30Days: return "Last 30 Days"
        case .allTime: return "All Time"
        }
    }

    var dayWindow: Int? {
        switch self {
        case .last7Days: return 7
        case .last30Days: return 30
        case .allTime: return nil
        }
    }
}
