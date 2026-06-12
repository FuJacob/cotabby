import Combine
import Foundation

/// Local, always-on counters that answer "is suggestion quality improving for real use": how many
/// completions were generated, how many were shown, why the withheld ones were withheld, and how
/// many shown suggestions the user actually accepted.
///
/// Latency tracking (`PerformanceMetricsStore`) stays opt-in because it records per-request rows;
/// these are lifetime counters with zero content, so they run unconditionally and survive restarts.
/// Acceptance rate (accepted / shown) is the closest thing to ground truth the app can measure on
/// device, and the suppression histogram tells the difference between "the model produced nothing"
/// and "a specific guard fired", which otherwise only exists scattered through debug-only JSONL.
@MainActor
final class SuggestionQualityMetricsStore: ObservableObject {
    struct Counters: Codable, Equatable {
        var generated = 0
        var shown = 0
        /// Sessions the user accepted at least once. Counted per suggestion, not per Tab press,
        /// so word-by-word acceptance of one suggestion is one acceptance.
        var acceptedSuggestions = 0
        /// Keyed by `CompletionSuppressionReason` raw values plus coordinator-level reasons
        /// (the seam guard verdicts). String-keyed so new reasons never need a schema migration.
        var suppressedByReason: [String: Int] = [:]
        var firstRecordedAt: Date?

        var suppressedTotal: Int { suppressedByReason.values.reduce(0, +) }

        var acceptanceRate: Double? {
            guard shown > 0 else { return nil }
            return Double(acceptedSuggestions) / Double(shown)
        }
    }

    @Published private(set) var counters: Counters

    private let userDefaults: UserDefaults
    private static let defaultsKey = "cotabbyQualityMetricsCounters"

    /// Stored-property @MainActor classes deallocated inside app-hosted tests double-free without
    /// an explicitly nonisolated deinit (the isolated-deinit runtime path over-releases). Same
    /// workaround as the other main-actor stores exercised by tests.
    nonisolated deinit {}

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(Counters.self, from: data) {
            counters = decoded
        } else {
            counters = Counters()
        }
    }

    func recordGenerated() {
        mutate { $0.generated += 1 }
    }

    func recordShown() {
        mutate { $0.shown += 1 }
    }

    func recordAcceptedSuggestion() {
        mutate { $0.acceptedSuggestions += 1 }
    }

    func recordSuppressed(reason: String) {
        mutate { $0.suppressedByReason[reason, default: 0] += 1 }
    }

    func reset() {
        counters = Counters()
        userDefaults.removeObject(forKey: Self.defaultsKey)
    }

    private func mutate(_ change: (inout Counters) -> Void) {
        var updated = counters
        change(&updated)
        if updated.firstRecordedAt == nil {
            updated.firstRecordedAt = Date()
        }
        counters = updated
        if let data = try? JSONEncoder().encode(updated) {
            userDefaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
