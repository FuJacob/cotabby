import XCTest
@testable import Cotabby

/// Tests for the lifetime suggestion-quality counters: accumulation, the acceptance rate, the
/// suppression-recovery reclassification, and durable persistence under a stable defaults key.
@MainActor
final class SuggestionQualityMetricsStoreTests: XCTestCase {
    /// Persisted-blob key, mirrored from the production constant so a silent rename fails here.
    private static let countersKey = "cotabbyQualityMetricsCounters"

    private func freshDefaults() -> UserDefaults {
        let suiteName = "CotabbyTests.qualityMetrics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testCountersAccumulate() {
        let store = SuggestionQualityMetricsStore(userDefaults: freshDefaults())
        XCTAssertNil(store.counters.firstRecordedAt)

        store.recordGenerated()
        store.recordGenerated()
        store.recordShown()
        store.recordAcceptedSuggestion()
        store.recordSuppressed(reason: "lowConfidence")
        store.recordSuppressed(reason: "lowConfidence")
        store.recordSuppressed(reason: "seamMisspelling")

        XCTAssertEqual(store.counters.generated, 2)
        XCTAssertEqual(store.counters.shown, 1)
        XCTAssertEqual(store.counters.acceptedSuggestions, 1)
        XCTAssertEqual(store.counters.suppressedByReason, ["lowConfidence": 2, "seamMisspelling": 1])
        XCTAssertEqual(store.counters.suppressedTotal, 3)
        XCTAssertNotNil(store.counters.firstRecordedAt)
    }

    func testFirstRecordedAtIsStampedOnceAndNeverMoves() throws {
        let store = SuggestionQualityMetricsStore(userDefaults: freshDefaults())
        store.recordGenerated()
        let first = try XCTUnwrap(store.counters.firstRecordedAt)

        store.recordShown()

        XCTAssertEqual(store.counters.firstRecordedAt, first)
    }

    func testAcceptanceRate() {
        let store = SuggestionQualityMetricsStore(userDefaults: freshDefaults())
        XCTAssertNil(store.counters.acceptanceRate, "no rate without shown suggestions")
        for _ in 0..<4 {
            store.recordShown()
        }
        store.recordAcceptedSuggestion()
        XCTAssertEqual(store.counters.acceptanceRate ?? 0, 0.25, accuracy: 0.0001)
    }

    // MARK: - Suppression recovery

    func testLocalFallbackReclassifiesSuppressedRequestAsShown() {
        let store = SuggestionQualityMetricsStore(userDefaults: freshDefaults())
        store.recordGenerated()
        store.recordSuppressed(reason: "emptyGeneration")
        store.recordShown(recoveringSuppression: "emptyGeneration")
        XCTAssertEqual(store.counters.generated, 1)
        XCTAssertEqual(store.counters.shown, 1)
        XCTAssertEqual(store.counters.suppressedTotal, 0)
        XCTAssertNil(store.counters.suppressedByReason["emptyGeneration"], "An emptied bucket is removed")
    }

    func testRecoveryDecrementsOnlyOneOfSeveralSuppressions() {
        let store = SuggestionQualityMetricsStore(userDefaults: freshDefaults())
        store.recordSuppressed(reason: "emptyGeneration")
        store.recordSuppressed(reason: "emptyGeneration")

        store.recordShown(recoveringSuppression: "emptyGeneration")

        XCTAssertEqual(store.counters.suppressedByReason["emptyGeneration"], 1)
        XCTAssertEqual(store.counters.shown, 1)
    }

    func testRecoveringAnUnrecordedReasonStillCountsShownWithoutGoingNegative() {
        let store = SuggestionQualityMetricsStore(userDefaults: freshDefaults())

        store.recordShown(recoveringSuppression: "neverRecorded")

        XCTAssertEqual(store.counters.shown, 1)
        XCTAssertTrue(store.counters.suppressedByReason.isEmpty)
    }

    // MARK: - Persistence

    func testPersistsAcrossInstancesUnderStableKey() {
        let defaults = freshDefaults()
        let first = SuggestionQualityMetricsStore(userDefaults: defaults)
        first.recordShown()
        first.recordSuppressed(reason: "emptyGeneration")

        XCTAssertNotNil(defaults.data(forKey: Self.countersKey))
        let second = SuggestionQualityMetricsStore(userDefaults: defaults)
        XCTAssertEqual(second.counters.shown, 1)
        XCTAssertEqual(second.counters.suppressedByReason, ["emptyGeneration": 1])
        XCTAssertNotNil(second.counters.firstRecordedAt)
    }

    func testCorruptPersistedBlobStartsFresh() {
        let defaults = freshDefaults()
        defaults.set(Data("not json".utf8), forKey: Self.countersKey)

        XCTAssertEqual(SuggestionQualityMetricsStore(userDefaults: defaults).counters, SuggestionQualityMetricsStore.Counters())
    }

    func testResetClearsEverything() {
        let defaults = freshDefaults()
        let store = SuggestionQualityMetricsStore(userDefaults: defaults)
        store.recordShown()
        store.reset()
        XCTAssertEqual(store.counters, SuggestionQualityMetricsStore.Counters())
        XCTAssertNil(defaults.data(forKey: Self.countersKey))
    }
}
