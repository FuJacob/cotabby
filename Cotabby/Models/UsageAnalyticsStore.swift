import Combine
import Foundation

/// Narrow persistence surface so the store can be unit-tested against an in-memory stand-in instead
/// of process-global `UserDefaults` (shared across tests and unreliable to mutate from a sandboxed
/// test host). `UserDefaults` already satisfies it, so production wiring is unchanged. Mirrors
/// `EmojiUsageDefaults`.
protocol UsageAnalyticsDefaults: AnyObject {
    func data(forKey defaultName: String) -> Data?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: UsageAnalyticsDefaults {}

/// File overview:
/// Persists local, privacy-preserving usage analytics for issue #489: per-day tallies of how many
/// suggestion chunks the user accepted and how many words and characters those chunks contained.
/// Backs the Usage settings pane and is written from `SuggestionCoordinator` at accept time.
///
/// What it deliberately never stores: any accepted text, prompt, OCR, screenshot, app identity, or
/// timestamp finer than the calendar day. The whole on-disk surface is `[day, acceptances, words,
/// characters]` rows, so it can only answer "how much did autocomplete help" and never "what did you
/// write".
///
/// `@MainActor` because the sole writer is the main-actor `SuggestionCoordinator` at commit time and
/// the sole reader is the main-actor settings pane. State is a single JSON blob so the read/write is
/// atomic.
///
/// The `deinit` is `nonisolated` to dodge the macOS 14 isolated-deinit back-deploy crash that
/// over-releases a `@MainActor` class with non-trivial stored properties and aborts the app-hosted
/// unit tests (see `EmojiUsageStore` for the full rationale).
@MainActor
final class UsageAnalyticsStore: ObservableObject {
    /// Day-sorted (oldest first) tallies. `private(set)` so only `recordAcceptance`/`clear` mutate it.
    @Published private(set) var buckets: [UsageAnalyticsDailyBucket]

    private let defaults: UsageAnalyticsDefaults
    private let calendar: Calendar
    private static let storageKey = "cotabbyUsageAnalytics"

    /// Versioned envelope so a future schema change can migrate the blob instead of silently
    /// discarding it.
    private struct Persisted: Codable {
        var version: Int
        var buckets: [UsageAnalyticsDailyBucket]
    }
    private static let currentVersion = 1

    init(defaults: UsageAnalyticsDefaults = UserDefaults.standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            buckets = decoded.buckets.sorted { $0.day < $1.day }
        } else {
            buckets = []
        }
    }

    // See the type doc comment: avoids the macOS 14 isolated-deinit back-deploy crash.
    nonisolated deinit {}

    /// Records one accepted suggestion chunk. `words` and `characters` come from the accepted text;
    /// the coordinator reuses `SuggestionSessionReconciler.acceptedWordCount` for `words` so this
    /// agrees with the menu-bar total. A fully empty accept is a no-op so it cannot inflate the
    /// acceptance count.
    func recordAcceptance(words: Int, characters: Int, date: Date = Date()) {
        guard words > 0 || characters > 0 else { return }
        buckets = UsageAnalyticsAggregator.recording(
            words: words,
            characters: characters,
            on: date,
            into: buckets,
            calendar: calendar
        )
        persist()
    }

    /// Totals for `range`, relative to `now` (injectable so tests can pin "today").
    func totals(in range: UsageAnalyticsRange, now: Date = Date()) -> UsageAnalyticsTotals {
        UsageAnalyticsAggregator.totals(in: buckets, range: range, now: now, calendar: calendar)
    }

    /// Dense, zero-filled per-day buckets for the last `days` days, oldest first. Drives the chart.
    func recentDailyBuckets(days: Int, now: Date = Date()) -> [UsageAnalyticsDailyBucket] {
        UsageAnalyticsAggregator.dailyBuckets(from: buckets, days: days, now: now, calendar: calendar)
    }

    /// Forgets all recorded analytics. Backs the pane's "Reset Stats" control.
    func clear() {
        guard !buckets.isEmpty else { return }
        buckets = []
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(
            Persisted(version: Self.currentVersion, buckets: buckets)
        ) else {
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }
}
