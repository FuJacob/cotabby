import XCTest
@testable import Cotabby

/// Tests for persisted emoji recents + frequency and the favorite rule the matcher reads.
///
/// Like the other main-actor suites in this target, the class itself is intentionally NOT
/// `@MainActor` (an `@MainActor` XCTestCase subclass crashes the app-hosted test runner); main-actor
/// work runs inside `runOnMainActor`. Persistence is exercised through an in-memory
/// `EmojiUsageDefaults` so the suite stays hermetic and never touches process-global UserDefaults.
final class EmojiUsageStoreTests: XCTestCase {
    /// Minimal in-memory stand-in for UserDefaults.
    private final class InMemoryDefaults: EmojiUsageDefaults {
        private var storage: [String: Data] = [:]
        func data(forKey defaultName: String) -> Data? { storage[defaultName] }
        func set(_ value: Any?, forKey defaultName: String) { storage[defaultName] = value as? Data }
        func removeObject(forKey defaultName: String) { storage[defaultName] = nil }
    }

    func test_recordPlacesMostRecentFirstAndCountsFrequency() {
        runOnMainActor {
            let sut = EmojiUsageStore(defaults: InMemoryDefaults())
            sut.record(alias: "joy")
            sut.record(alias: "fire")
            sut.record(alias: "joy")

            let snapshot = sut.snapshot()
            XCTAssertEqual(snapshot.recentAliases, ["joy", "fire"])   // re-used joy returns to front, deduped
            XCTAssertEqual(snapshot.frequency["joy"], 2)
            XCTAssertEqual(snapshot.frequency["fire"], 1)
        }
    }

    func test_recordNormalizesAndIgnoresBlank() {
        runOnMainActor {
            let sut = EmojiUsageStore(defaults: InMemoryDefaults())
            sut.record(alias: "  JOY  ")
            sut.record(alias: "   ")

            let snapshot = sut.snapshot()
            XCTAssertEqual(snapshot.recentAliases, ["joy"])
            XCTAssertEqual(snapshot.frequency["joy"], 1)
        }
    }

    func test_recentsAreCappedKeepingNewest() {
        runOnMainActor {
            let sut = EmojiUsageStore(defaults: InMemoryDefaults())
            for index in 0..<60 {
                sut.record(alias: "alias\(index)")
            }

            let snapshot = sut.snapshot()
            XCTAssertEqual(snapshot.recentAliases.count, 50)
            XCTAssertEqual(snapshot.recentAliases.first, "alias59")    // newest first
            XCTAssertFalse(snapshot.recentAliases.contains("alias0"))  // oldest fell off the cap
        }
    }

    func test_clearForgetsEverything() {
        runOnMainActor {
            let sut = EmojiUsageStore(defaults: InMemoryDefaults())
            sut.record(alias: "joy")
            sut.clear()

            let snapshot = sut.snapshot()
            XCTAssertTrue(snapshot.recentAliases.isEmpty)
            XCTAssertTrue(snapshot.frequency.isEmpty)
        }
    }

    func test_statePersistsAcrossInstances() {
        runOnMainActor {
            let defaults = InMemoryDefaults()
            EmojiUsageStore(defaults: defaults).record(alias: "rocket")

            let reopened = EmojiUsageStore(defaults: defaults)   // new instance, same backing store
            XCTAssertEqual(reopened.snapshot().recentAliases, ["rocket"])
            XCTAssertEqual(reopened.snapshot().frequency["rocket"], 1)
        }
    }

    func test_isFavoriteHonorsRecencyAndFrequency() {
        let recentOnly = EmojiUsageSnapshot(recentAliases: ["wave"], frequency: [:])
        XCTAssertTrue(recentOnly.isFavorite("wave"))
        XCTAssertFalse(recentOnly.isFavorite("fire"))

        let frequentEnough = EmojiUsageSnapshot(recentAliases: [], frequency: ["fire": 2])
        XCTAssertTrue(frequentEnough.isFavorite("fire"))

        let usedOnce = EmojiUsageSnapshot(recentAliases: [], frequency: ["fire": 1])
        XCTAssertFalse(usedOnce.isFavorite("fire"))
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
