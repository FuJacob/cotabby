import XCTest
@testable import Cotabby

/// Tests for the single-slot field text-style cache. The contract: the expensive cross-process
/// style read runs once per focused element, a "host exposes no style" nil answer is cached too,
/// and moving to another element (even and especially back to an earlier one) reads again.
@MainActor
final class FieldStyleCacheTests: XCTestCase {
    private let menlo = ResolvedFieldStyle(fontName: "Menlo-Regular", fontPointSize: 13, colorHex: "112233")
    private let helvetica = ResolvedFieldStyle(fontName: "Helvetica", fontPointSize: 12, colorHex: nil)

    func test_resolvesOncePerElement() {
        let cache = FieldStyleCache()
        var reads = 0

        let first = cache.style(forKey: "field-a") { reads += 1; return menlo }
        let second = cache.style(forKey: "field-a") { reads += 1; return helvetica }

        XCTAssertEqual(first, menlo)
        XCTAssertEqual(second, menlo)
        XCTAssertEqual(reads, 1)
    }

    /// Plain fields expose no style; without caching the nil they would be re-probed every poll.
    func test_cachesANilStyle() {
        let cache = FieldStyleCache()
        var reads = 0

        let first = cache.style(forKey: "plain") { reads += 1; return nil }
        let second = cache.style(forKey: "plain") { reads += 1; return menlo }

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(reads, 1)
    }

    /// The cache holds one slot, so returning to an earlier field must read again rather than
    /// serve a style captured before the other field was focused.
    func test_keyChangeResolvesAgainAndReplacesTheSlot() {
        let cache = FieldStyleCache()
        var reads = 0

        _ = cache.style(forKey: "field-a") { reads += 1; return menlo }
        let otherField = cache.style(forKey: "field-b") { reads += 1; return helvetica }
        let backToFirst = cache.style(forKey: "field-a") { reads += 1; return helvetica }

        XCTAssertEqual(otherField, helvetica)
        XCTAssertEqual(backToFirst, helvetica)
        XCTAssertEqual(reads, 3)
    }
}
