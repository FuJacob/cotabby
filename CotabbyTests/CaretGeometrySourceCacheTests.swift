import ApplicationServices
import XCTest
@testable import Cotabby

/// Tests for `CaretGeometrySourceCache` key matching and invalidation.
///
/// The cache stores live `AXUIElement` references, so these tests use a real system-wide element as
/// an opaque stand-in — the behavior under test is the per-field keying and eviction, not the AX
/// content of the elements themselves.
@MainActor
final class CaretGeometrySourceCacheTests: XCTestCase {
    private let element = AXUIElementCreateSystemWide()

    private func key(_ identifier: String, _ sequence: UInt64) -> CaretGeometrySourceCache.FieldKey {
        CaretGeometrySourceCache.FieldKey(containerIdentifier: identifier, focusChangeSequence: sequence)
    }

    func testColdCacheReturnsNil() {
        let cache = CaretGeometrySourceCache()
        XCTAssertNil(cache.textRunElements(for: key("field", 1)))
        XCTAssertNil(cache.deepSource(for: key("field", 1)))
    }

    func testRunElementsHitOnMatchingKey() {
        let cache = CaretGeometrySourceCache()
        cache.store(textRunElements: [element], for: key("field", 1))
        XCTAssertEqual(cache.textRunElements(for: key("field", 1))?.count, 1)
    }

    func testRunElementsMissOnDifferentSequence() {
        let cache = CaretGeometrySourceCache()
        cache.store(textRunElements: [element], for: key("field", 1))
        // A focus change bumps the sequence, which must invalidate the previous field's entry even
        // though the container identifier (a CFHash) could collide across recycled nodes.
        XCTAssertNil(cache.textRunElements(for: key("field", 2)))
    }

    func testStoringNewKeyEvictsPrevious() {
        let cache = CaretGeometrySourceCache()
        cache.store(textRunElements: [element], for: key("a", 1))
        cache.store(textRunElements: [element], for: key("b", 1))
        XCTAssertNil(cache.textRunElements(for: key("a", 1)))
        XCTAssertEqual(cache.textRunElements(for: key("b", 1))?.count, 1)
    }

    func testRunAndDeepEntriesAreIndependent() {
        let cache = CaretGeometrySourceCache()
        cache.store(textRunElements: [element], for: key("field", 1))
        // Caching runs must not imply a deep-source entry, and vice versa.
        XCTAssertNil(cache.deepSource(for: key("field", 1)))

        cache.store(deepSource: element, for: key("field", 1))
        XCTAssertNotNil(cache.deepSource(for: key("field", 1)))
        XCTAssertEqual(cache.textRunElements(for: key("field", 1))?.count, 1)
    }

    func testInvalidateClearsBoth() {
        let cache = CaretGeometrySourceCache()
        cache.store(textRunElements: [element], for: key("field", 1))
        cache.store(deepSource: element, for: key("field", 1))

        cache.invalidate()

        XCTAssertNil(cache.textRunElements(for: key("field", 1)))
        XCTAssertNil(cache.deepSource(for: key("field", 1)))
    }
}
