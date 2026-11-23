import XCTest
@testable import Cotabby

/// Tests for the load-state and eviction rules behind the spelling dictionary cache.
final class BoundedLoadCacheTests: XCTestCase {
    private func value(_ lookup: BoundedLoadCache<String, Int>.Lookup) -> Int? {
        if case .ready(let value) = lookup { return value }
        return nil
    }

    private func isStartLoad(_ lookup: BoundedLoadCache<String, Int>.Lookup) -> Bool {
        if case .startLoad = lookup { return true }
        return false
    }

    private func isLoading(_ lookup: BoundedLoadCache<String, Int>.Lookup) -> Bool {
        if case .loading = lookup { return true }
        return false
    }

    func test_aColdKeyStartsExactlyOneLoad() {
        var cache = BoundedLoadCache<String, Int>(limit: 2)

        XCTAssertTrue(isStartLoad(cache.lookup("en")))
        XCTAssertTrue(isLoading(cache.lookup("en")), "A second lookup must not start a second load")
        XCTAssertEqual(cache.readyKeys, [])
    }

    func test_aPublishedValueIsReturnedByLaterLookups() {
        var cache = BoundedLoadCache<String, Int>(limit: 2)
        _ = cache.lookup("en")

        cache.publish(1, for: "en")

        XCTAssertEqual(value(cache.lookup("en")), 1)
        XCTAssertEqual(cache.readyKeys, ["en"])
    }

    func test_aFailedLoadCanBeRetried() {
        var cache = BoundedLoadCache<String, Int>(limit: 2)
        _ = cache.lookup("en")

        cache.loadFailed(for: "en")

        XCTAssertTrue(isStartLoad(cache.lookup("en")))
    }

    func test_aFailedLoadDoesNotDiscardAValuePublishedInTheMeantime() {
        var cache = BoundedLoadCache<String, Int>(limit: 2)
        _ = cache.lookup("en")
        cache.publish(1, for: "en")

        cache.loadFailed(for: "en")

        XCTAssertEqual(value(cache.lookup("en")), 1)
    }

    func test_publishingBeyondTheLimitEvictsTheLeastRecentlyUsedValue() {
        var cache = BoundedLoadCache<String, Int>(limit: 2)
        cache.publish(1, for: "en")
        cache.publish(2, for: "de")
        // Reading English makes German the least recently used.
        _ = cache.lookup("en")

        cache.publish(3, for: "es")

        XCTAssertEqual(Set(cache.readyKeys), ["en", "es"])
        XCTAssertTrue(isStartLoad(cache.lookup("de")), "An evicted key loads again on demand")
    }

    func test_keysThatAreStillLoadingDoNotCountTowardTheLimitAndAreNotEvicted() {
        var cache = BoundedLoadCache<String, Int>(limit: 1)
        _ = cache.lookup("de")

        cache.publish(1, for: "en")

        XCTAssertEqual(cache.readyKeys, ["en"])
        XCTAssertTrue(isLoading(cache.lookup("de")))
    }

    func test_aLimitBelowOneStillKeepsOneValue() {
        var cache = BoundedLoadCache<String, Int>(limit: 0)

        cache.publish(1, for: "en")

        XCTAssertEqual(cache.readyKeys, ["en"])
    }
}
