import XCTest
@testable import Cotabby

/// The optimistic snapshot must reproduce, field for field, what the host is expected to publish
/// after the insert: same identity and geometry, preceding text extended by exactly the inserted
/// chunk, caret advanced by its UTF-16 length. Its content signature is the validation token the
/// speculation machinery compares against the real publish.
final class SpeculativeAcceptanceContextTests: XCTestCase {
    func testAppendsInsertionAndAdvancesCaret() {
        let base = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
        let optimistic = SpeculativeAcceptanceContext.optimisticSnapshot(after: base, inserting: " world")

        XCTAssertEqual(optimistic.precedingText, "Hello world")
        XCTAssertEqual(optimistic.selection.location, base.selection.location + " world".utf16.count)
        XCTAssertEqual(optimistic.selection.length, 0)
        XCTAssertEqual(optimistic.trailingText, base.trailingText)
        XCTAssertEqual(optimistic.elementIdentifier, base.elementIdentifier)
        XCTAssertEqual(optimistic.focusChangeSequence, base.focusChangeSequence)
    }

    func testUTF16AdvanceCountsSurrogatePairs() {
        let base = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Nice ")
        let optimistic = SpeculativeAcceptanceContext.optimisticSnapshot(after: base, inserting: "🎉🎉")
        XCTAssertEqual(optimistic.selection.location, base.selection.location + 4)
    }

    func testSignatureMatchesAnIdenticalRealPublish() {
        let base = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
        let optimistic = SpeculativeAcceptanceContext.optimisticSnapshot(after: base, inserting: " world")
        let published = CotabbyTestFixtures.focusedInputSnapshot(
            precedingText: "Hello world",
            selection: NSRange(location: optimistic.selection.location, length: 0)
        )
        XCTAssertEqual(optimistic.contentSignature, published.contentSignature)
    }

    func testSignatureDiffersWhenHostTransformedTheText() {
        let base = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
        let optimistic = SpeculativeAcceptanceContext.optimisticSnapshot(after: base, inserting: " world")
        let autocorrected = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello World")
        XCTAssertNotEqual(optimistic.contentSignature, autocorrected.contentSignature)
    }
}
