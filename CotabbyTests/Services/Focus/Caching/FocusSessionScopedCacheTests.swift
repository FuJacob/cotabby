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

    // MARK: - Explicit lookup and store

    /// The line-margin cache stores optional results, and "looked, found nothing" must stay distinct
    /// from "never looked": the first is a cached answer, the second means the lookup has to run.
    func test_cachedValueDistinguishesAStoredNilFromAMiss() {
        let cache = FocusSessionScopedCache<Int?>()

        XCTAssertNil(cache.cachedValue(forKey: "paragraph", focusChangeSequence: 1), "nothing stored yet")

        cache.store(nil, forKey: "paragraph", focusChangeSequence: 1)
        // `cachedValue` returns `Int??` here: the outer optional is "is there an entry".
        guard case .some(let entry) = cache.cachedValue(forKey: "paragraph", focusChangeSequence: 1) else {
            return XCTFail("a stored nil is still an entry")
        }
        XCTAssertNil(entry, "and that entry's value is nil")
    }

    func test_storeReplacesAnEntryWithinTheSession() {
        let cache = FocusSessionScopedCache<Int>()

        cache.store(1, forKey: "paragraph", focusChangeSequence: 4)
        cache.store(2, forKey: "paragraph", focusChangeSequence: 4)

        XCTAssertEqual(cache.cachedValue(forKey: "paragraph", focusChangeSequence: 4), 2)
    }

    func test_explicitLookupNeverCrossesASequenceChange() {
        let cache = FocusSessionScopedCache<Int>()

        cache.store(1, forKey: "paragraph", focusChangeSequence: 4)

        XCTAssertNil(cache.cachedValue(forKey: "paragraph", focusChangeSequence: 5))
        // The earlier session's entry is gone for good, not just hidden.
        XCTAssertNil(cache.cachedValue(forKey: "paragraph", focusChangeSequence: 4))
    }
}
