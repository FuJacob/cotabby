import XCTest
@testable import Cotabby

/// Tests for the focus-session-scoped AX read cache. The contract that matters: values are reused
/// within one focus-change sequence (that is the IPC saving) and never survive a sequence change
/// (that is what makes caching secure-field verdicts safe despite recycled element identities).
@MainActor
final class FocusSessionScopedCacheTests: XCTestCase {
    func test_reusesValueWithinSameSequence() {
        let cache = FocusSessionScopedCache<Bool>()
        var computeCount = 0

        let first = cache.value(forKey: "el-1", focusChangeSequence: 7) {
            computeCount += 1
            return true
        }
        let second = cache.value(forKey: "el-1", focusChangeSequence: 7) {
            computeCount += 1
            return false
        }

        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(computeCount, 1)
    }

    func test_tracksDistinctKeysIndependently() {
        let cache = FocusSessionScopedCache<Int>()

        XCTAssertEqual(cache.value(forKey: "a", focusChangeSequence: 1) { 10 }, 10)
        XCTAssertEqual(cache.value(forKey: "b", focusChangeSequence: 1) { 20 }, 20)
        XCTAssertEqual(cache.value(forKey: "a", focusChangeSequence: 1) { 99 }, 10)
    }

    func test_sequenceChangeDropsAllEntries() {
        let cache = FocusSessionScopedCache<Bool>()

        XCTAssertFalse(cache.value(forKey: "recycled-id", focusChangeSequence: 1) { false })
        // Same key after a field switch must recompute: the identity may belong to a different
        // element now (CFHash recycling), and a stale "not secure" verdict would be unsafe.
        XCTAssertTrue(cache.value(forKey: "recycled-id", focusChangeSequence: 2) { true })
    }
}
