import XCTest
@testable import Cotabby

final class BoundedCacheTests: XCTestCase {
    func test_holdsEntriesUpToItsLimit() {
        var cache = BoundedCache<String, Int>(limit: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")

        XCTAssertEqual(cache["a"], 1)
        XCTAssertEqual(cache["b"], 2)
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache["c"])
    }

    func test_aNewKeyPastTheLimitEvictsTheOldestInserted() {
        var cache = BoundedCache<String, Int>(limit: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        cache.insert(3, for: "c")

        XCTAssertNil(cache["a"])
        XCTAssertEqual(cache["b"], 2)
        XCTAssertEqual(cache["c"], 3)
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.keys, ["b", "c"], "keys are listed oldest first")
    }

    func test_replacingAValueKeepsTheKeysPlaceInLine() {
        var cache = BoundedCache<String, Int>(limit: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        cache.insert(10, for: "a")
        XCTAssertEqual(cache["a"], 10)
        XCTAssertEqual(cache.count, 2)

        XCTAssertEqual(cache.keys, ["a", "b"])

        // "a" was inserted first, so it is still the one to go: eviction is not by recency of use.
        cache.insert(3, for: "c")
        XCTAssertNil(cache["a"])
        XCTAssertEqual(cache["b"], 2)
        XCTAssertEqual(cache["c"], 3)
    }

    func test_anEvictedKeyCanBeInsertedAgain() {
        var cache = BoundedCache<Int, String>(limit: 1)
        cache.insert("one", for: 1)
        cache.insert("two", for: 2)
        cache.insert("one again", for: 1)

        XCTAssertEqual(cache[1], "one again")
        XCTAssertNil(cache[2])
    }
}
