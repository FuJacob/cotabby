import Foundation
import XCTest
@testable import Cotabby

/// Persistence and ring-buffer behavior of the latency metrics behind the Performance pane.
///
/// `PerformanceMetricsStore` is `@MainActor` with stored properties and no `nonisolated deinit`,
/// so deallocating an instance inside the app-hosted runner risks the isolated-deinit double-free.
/// Instances are quarantined in a process-lifetime retain list (the same pattern as
/// `InputMonitorTests`), and each test gets its own UserDefaults suite so nothing touches
/// process-global state.
final class PerformanceMetricsStoreTests: XCTestCase {
    @MainActor private static var retainedStores: [PerformanceMetricsStore] = []

    /// Persisted-blob key, mirrored from the production constant: it is a persistence contract,
    /// so a silent rename should fail a test.
    private static let entriesKey = "cotabbyPerformanceMetricEntries"

    private var userDefaultsSuites: [(suiteName: String, userDefaults: UserDefaults)] = []

    override func tearDown() {
        for suite in userDefaultsSuites {
            suite.userDefaults.removePersistentDomain(forName: suite.suiteName)
        }
        userDefaultsSuites.removeAll()
        super.tearDown()
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "io.cotabby.tests.PerformanceMetricsStoreTests-\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected an isolated UserDefaults suite")
            return .standard
        }
        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaultsSuites.append((suiteName: suiteName, userDefaults: userDefaults))
        return userDefaults
    }

    @MainActor
    private func makeStore(userDefaults: UserDefaults) -> PerformanceMetricsStore {
        let store = PerformanceMetricsStore(userDefaults: userDefaults)
        Self.retainedStores.append(store)
        return store
    }

    /// Integer-second dates encode to exact JSON doubles, keeping Codable round-trip equality
    /// deterministic (fractional timestamps can lose ULPs through the JSON text form).
    private func exactDate(offset: Int = 0) -> Date {
        Date(timeIntervalSince1970: TimeInterval(1_750_000_000 + offset))
    }

    private func decodePersistedEntries(from userDefaults: UserDefaults) -> [PerformanceMetricEntry]? {
        guard let data = userDefaults.data(forKey: Self.entriesKey) else { return nil }
        return try? JSONDecoder().decode([PerformanceMetricEntry].self, from: data)
    }

    // MARK: - Recording

    func test_record_appendsEntryAndPersistsBlob() {
        let userDefaults = makeUserDefaults()

        runOnMainActor {
            let store = makeStore(userDefaults: userDefaults)
            store.record(modelName: "tabby-2-nano", latencyMs: 230, timestamp: exactDate())

            XCTAssertEqual(store.entries.count, 1)
            XCTAssertEqual(store.entries.first?.modelName, "tabby-2-nano")
            XCTAssertEqual(store.entries.first?.latencyMs, 230)
            XCTAssertEqual(store.entries.first?.timestamp, exactDate())

            XCTAssertEqual(decodePersistedEntries(from: userDefaults), store.entries)
        }
    }

    func test_record_capsRetainedEntriesDroppingOldest() {
        let userDefaults = makeUserDefaults()
        let cap = runOnMainActor { PerformanceMetricsStore.maximumEntries }

        runOnMainActor {
            let store = makeStore(userDefaults: userDefaults)
            for index in 0..<(cap + 5) {
                store.record(modelName: "model", latencyMs: index, timestamp: exactDate(offset: index))
            }

            XCTAssertEqual(store.entries.count, cap)
            XCTAssertEqual(store.entries.first?.latencyMs, 5, "Oldest five entries should have fallen off")
            XCTAssertEqual(store.entries.last?.latencyMs, cap + 4)
            XCTAssertEqual(decodePersistedEntries(from: userDefaults), store.entries, "Persisted blob mirrors the cap")
        }
    }

    // MARK: - Loading

    func test_init_restoresPersistedEntries() throws {
        let userDefaults = makeUserDefaults()
        let seeded = [
            PerformanceMetricEntry(timestamp: exactDate(), modelName: "alpha", latencyMs: 100),
            PerformanceMetricEntry(timestamp: exactDate(offset: 1), modelName: "beta", latencyMs: 200)
        ]
        userDefaults.set(try JSONEncoder().encode(seeded), forKey: Self.entriesKey)

        runOnMainActor {
            let store = makeStore(userDefaults: userDefaults)
            XCTAssertEqual(store.entries, seeded)
        }
    }

    func test_init_truncatesOversizedPersistedBlobKeepingNewest() throws {
        let userDefaults = makeUserDefaults()
        let cap = runOnMainActor { PerformanceMetricsStore.maximumEntries }
        let seeded = (0..<(cap + 5)).map { index in
            PerformanceMetricEntry(timestamp: exactDate(offset: index), modelName: "model", latencyMs: index)
        }
        userDefaults.set(try JSONEncoder().encode(seeded), forKey: Self.entriesKey)

        runOnMainActor {
            let store = makeStore(userDefaults: userDefaults)
            XCTAssertEqual(store.entries.count, cap)
            XCTAssertEqual(store.entries, Array(seeded.suffix(cap)), "Truncation keeps the newest tail")
        }
    }

    func test_init_startsEmptyWhenPersistedBlobIsCorrupt() {
        let userDefaults = makeUserDefaults()
        userDefaults.set(Data("not json".utf8), forKey: Self.entriesKey)

        runOnMainActor {
            let store = makeStore(userDefaults: userDefaults)
            XCTAssertTrue(store.entries.isEmpty)
        }
    }

    // MARK: - Clearing

    func test_clear_removesEntriesAndPersistedBlob() {
        let userDefaults = makeUserDefaults()

        runOnMainActor {
            let store = makeStore(userDefaults: userDefaults)
            store.record(modelName: "model", latencyMs: 50, timestamp: exactDate())

            store.clear()

            XCTAssertTrue(store.entries.isEmpty)
            XCTAssertNil(userDefaults.data(forKey: Self.entriesKey))
        }
    }

    func test_clear_whenAlreadyEmpty_skipsTheDefaultsWrite() {
        let userDefaults = makeUserDefaults()
        // Corrupt seed data loads as "no entries" but stays on disk; an empty clear must take the
        // guard path and not touch the key.
        let corrupt = Data("not json".utf8)
        userDefaults.set(corrupt, forKey: Self.entriesKey)

        runOnMainActor {
            let store = makeStore(userDefaults: userDefaults)
            XCTAssertTrue(store.entries.isEmpty)

            store.clear()

            XCTAssertEqual(userDefaults.data(forKey: Self.entriesKey), corrupt)
        }
    }

    // MARK: - Entry value semantics

    func test_metricEntry_defaultsProvideUniqueIdentityAndCurrentTimestamp() {
        let before = Date()
        let first = PerformanceMetricEntry(modelName: "model", latencyMs: 10)
        let second = PerformanceMetricEntry(modelName: "model", latencyMs: 10)
        let after = Date()

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertGreaterThanOrEqual(first.timestamp, before)
        XCTAssertLessThanOrEqual(first.timestamp, after)
    }

    func test_metricEntry_roundTripsThroughJSON() throws {
        // The entry's synthesized Codable/Equatable inherit the app module's default MainActor
        // isolation, so the round trip runs through the main-actor hop helper.
        try runOnMainActor {
            let entry = PerformanceMetricEntry(timestamp: exactDate(), modelName: "tabby-2-mini", latencyMs: 412)

            let decoded = try JSONDecoder().decode(
                PerformanceMetricEntry.self,
                from: JSONEncoder().encode(entry)
            )

            XCTAssertEqual(decoded, entry)
            XCTAssertEqual(decoded.hashValue, entry.hashValue)
        }
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
