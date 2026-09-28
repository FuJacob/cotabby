import XCTest
@testable import Cotabby

/// Tests for the field text-style cache. The contract: the expensive cross-process style read runs
/// once per style run of a focused element, an empty "host exposes no style yet" answer is retried
/// a bounded number of times (Chromium builds its text boxes lazily) and then cached, and moving to
/// another element (even and especially back to an earlier one) reads again.
@MainActor
final class FieldStyleCacheTests: XCTestCase {
    private let menlo = ResolvedFieldStyle(fontName: "Menlo-Regular", fontPointSize: 13, colorHex: "112233")
    private let helvetica = ResolvedFieldStyle(fontName: "Helvetica", fontPointSize: 12, colorHex: nil)

    /// One whole-field style run, as an AppKit host without rich text reports it.
    private let wholeField = NSRange(location: 0, length: 100)

    private func read(
        _ cache: FieldStyleCache, key: String, caret: Int = 5, now: Date = Date(),
        run: NSRange?, reads: inout Int, style: ResolvedFieldStyle?
    ) -> ResolvedFieldStyle? {
        cache.style(forKey: key, caretLocation: caret, caretHeight: 18, now: now, styleRun: { run }) {
            reads += 1
            return style
        }
    }

    func test_resolvesOncePerStyleRun() {
        let cache = FieldStyleCache()
        var reads = 0

        let first = read(cache, key: "field-a", caret: 5, run: wholeField, reads: &reads, style: menlo)
        let second = read(cache, key: "field-a", caret: 40, run: wholeField, reads: &reads, style: helvetica)

        XCTAssertEqual(first, menlo)
        XCTAssertEqual(second, menlo, "a caret still inside the cached run reuses the style")
        XCTAssertEqual(reads, 1)
    }

    /// Chromium answers nil until its inline text boxes exist, so a nil is retried (spaced by the
    /// retry interval) rather than frozen; once the host answers, that answer is kept.
    func test_retriesANilStyleUntilTheHostAnswers() {
        let cache = FieldStyleCache()
        var reads = 0
        let start = Date()

        XCTAssertNil(read(cache, key: "web", now: start, run: nil, reads: &reads, style: nil))
        XCTAssertNil(
            read(cache, key: "web", now: start.addingTimeInterval(0.05), run: nil, reads: &reads, style: menlo),
            "a poll inside the retry interval does not re-read"
        )
        XCTAssertEqual(reads, 1)

        let answered = read(cache, key: "web", now: start.addingTimeInterval(1), run: nil, reads: &reads, style: menlo)
        XCTAssertEqual(answered, menlo)
        XCTAssertEqual(reads, 2)
    }

    /// A host that never answers is asked at most `maximumAttempts` times, then nil is cached.
    func test_boundsTheNilRetries() {
        let cache = FieldStyleCache()
        var reads = 0
        let start = Date()

        for tick in 0..<(FieldStyleCache.maximumAttempts + 3) {
            _ = read(cache, key: "plain", now: start.addingTimeInterval(Double(tick)), run: nil, reads: &reads, style: nil)
        }

        XCTAssertEqual(reads, FieldStyleCache.maximumAttempts)
    }

    /// The cache holds one slot, so returning to an earlier field must read again rather than
    /// serve a style captured before the other field was focused.
    func test_keyChangeResolvesAgainAndReplacesTheSlot() {
        let cache = FieldStyleCache()
        var reads = 0

        _ = read(cache, key: "field-a", run: wholeField, reads: &reads, style: menlo)
        let otherField = read(cache, key: "field-b", run: wholeField, reads: &reads, style: helvetica)
        let backToFirst = read(cache, key: "field-a", run: wholeField, reads: &reads, style: helvetica)

        XCTAssertEqual(otherField, helvetica)
        XCTAssertEqual(backToFirst, helvetica)
        XCTAssertEqual(reads, 3)
    }

    /// Rich-text hosts change font between runs: a caret that leaves the cached run reads again.
    func test_caretLeavingTheStyleRunResolvesAgain() {
        let cache = FieldStyleCache()
        var reads = 0

        let heading = read(cache, key: "doc", caret: 3, run: NSRange(location: 0, length: 10), reads: &reads, style: helvetica)
        let body = read(cache, key: "doc", caret: 30, run: NSRange(location: 10, length: 90), reads: &reads, style: menlo)

        XCTAssertEqual(heading, helvetica)
        XCTAssertEqual(body, menlo)
        XCTAssertEqual(reads, 2)
    }
}
