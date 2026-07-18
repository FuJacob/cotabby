import XCTest
@testable import Cotabby

@MainActor
final class SuggestionQualityMetricsStoreTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "CotabbyTests.qualityMetrics.\(UUID().uuidString)") ?? .standard
    }

    func testCountersAccumulate() {
        let store = SuggestionQualityMetricsStore(userDefaults: freshDefaults())
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
        XCTAssertEqual(store.counters.suppressedByReason["lowConfidence"], 2)
        XCTAssertEqual(store.counters.suppressedByReason["seamMisspelling"], 1)
        XCTAssertEqual(store.counters.suppressedTotal, 3)
        XCTAssertNotNil(store.counters.firstRecordedAt)
    }

    func testAcceptanceRate() {
        let store = SuggestionQualityMetricsStore(userDefaults: freshDefaults())
        XCTAssertNil(store.counters.acceptanceRate, "no rate without shown suggestions")
        store.recordShown()
        store.recordShown()
        store.recordShown()
        store.recordShown()
        store.recordAcceptedSuggestion()
        XCTAssertEqual(store.counters.acceptanceRate ?? 0, 0.25, accuracy: 0.0001)
    }

    func testPersistsAcrossInstances() {
        let defaults = freshDefaults()
        let first = SuggestionQualityMetricsStore(userDefaults: defaults)
        first.recordShown()
        first.recordSuppressed(reason: "emptyGeneration")

        let second = SuggestionQualityMetricsStore(userDefaults: defaults)
        XCTAssertEqual(second.counters.shown, 1)
        XCTAssertEqual(second.counters.suppressedByReason["emptyGeneration"], 1)
    }

    func testResetClearsEverything() {
        let defaults = freshDefaults()
        let store = SuggestionQualityMetricsStore(userDefaults: defaults)
        store.recordShown()
        store.reset()
        XCTAssertEqual(store.counters, SuggestionQualityMetricsStore.Counters())
        XCTAssertEqual(SuggestionQualityMetricsStore(userDefaults: defaults).counters.shown, 0)
    }
}
