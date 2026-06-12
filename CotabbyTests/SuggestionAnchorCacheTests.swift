import XCTest
@testable import Cotabby

/// Pins the single match rule that powers instant re-shows: live tail == anchor tail + the first
/// `k` suggestion characters, `k` strictly short of the whole suggestion, freshest and deepest
/// match first.
final class SuggestionAnchorCacheTests: XCTestCase {
    private var clock: Date = .init(timeIntervalSince1970: 1_000_000)
    private func makeCache() -> SuggestionAnchorCache {
        SuggestionAnchorCache(now: { self.clock })
    }

    func testFreshAnchorMatchesAtZeroConsumed() {
        var cache = makeCache()
        cache.record(identityKey: 1, precedingText: "Hello", fullText: " world again")
        XCTAssertEqual(cache.remainder(identityKey: 1, precedingText: "Hello"), " world again")
    }

    func testTypeThroughConsumesPrefix() {
        var cache = makeCache()
        cache.record(identityKey: 1, precedingText: "Hello", fullText: " world again")
        XCTAssertEqual(cache.remainder(identityKey: 1, precedingText: "Hello wo"), "rld again")
    }

    func testBackspaceRollbackRestoresEarlierPosition() {
        var cache = makeCache()
        cache.record(identityKey: 1, precedingText: "Hello", fullText: " world again")
        // The user typed " worl", then backspaced twice to "Hello wo".
        XCTAssertEqual(cache.remainder(identityKey: 1, precedingText: "Hello wo"), "rld again")
        XCTAssertEqual(cache.remainder(identityKey: 1, precedingText: "Hello"), " world again")
    }

    func testFullyConsumedSuggestionNeverReoffersItsTail() {
        var cache = makeCache()
        cache.record(identityKey: 1, precedingText: "Hello", fullText: " world")
        XCTAssertNil(
            cache.remainder(identityKey: 1, precedingText: "Hello world"),
            "k must stay strictly below the suggestion length"
        )
    }

    func testDivergentTypingDoesNotMatch() {
        var cache = makeCache()
        cache.record(identityKey: 1, precedingText: "Hello", fullText: " world again")
        XCTAssertNil(cache.remainder(identityKey: 1, precedingText: "Hello wa"))
    }

    func testDifferentFieldDoesNotMatch() {
        var cache = makeCache()
        cache.record(identityKey: 1, precedingText: "Hello", fullText: " world")
        XCTAssertNil(cache.remainder(identityKey: 2, precedingText: "Hello"))
    }

    func testDeepestConsumedMatchWins() {
        var cache = makeCache()
        cache.record(identityKey: 1, precedingText: "Hello", fullText: " world again")
        cache.record(identityKey: 1, precedingText: "Hello wo", fullText: "rld forever")
        // Both anchors are consistent with "Hello wor": the first at k=4, the second at k=1.
        // The deeper consumed prefix is the first anchor, resuming closest to the caret.
        XCTAssertEqual(cache.remainder(identityKey: 1, precedingText: "Hello wor"), "ld again")
    }

    func testEntriesExpire() {
        var cache = makeCache()
        cache.record(identityKey: 1, precedingText: "Hello", fullText: " world")
        clock = clock.addingTimeInterval(SuggestionAnchorCache.maxEntryAge + 1)
        XCTAssertNil(cache.remainder(identityKey: 1, precedingText: "Hello"))
    }

    func testCapacityEvictsOldest() {
        var cache = makeCache()
        for index in 0 ..< (SuggestionAnchorCache.capacity + 4) {
            cache.record(identityKey: 1, precedingText: "prefix \(index)", fullText: "suffix \(index)")
        }
        XCTAssertNil(cache.remainder(identityKey: 1, precedingText: "prefix 0"))
        XCTAssertEqual(
            cache.remainder(identityKey: 1, precedingText: "prefix \(SuggestionAnchorCache.capacity + 3)"),
            "suffix \(SuggestionAnchorCache.capacity + 3)"
        )
    }

    func testLongPrefixesMatchOnTheBoundedTail() {
        var cache = makeCache()
        let longPrefix = String(repeating: "a", count: 2000) + " ending here"
        cache.record(identityKey: 1, precedingText: longPrefix, fullText: " and more")
        XCTAssertEqual(cache.remainder(identityKey: 1, precedingText: longPrefix + " and"), " more")
    }

    func testRemoveAllEmptiesTheCache() {
        var cache = makeCache()
        cache.record(identityKey: 1, precedingText: "Hello", fullText: " world")
        cache.removeAll()
        XCTAssertNil(cache.remainder(identityKey: 1, precedingText: "Hello"))
    }
}
