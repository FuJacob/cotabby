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

    func testReplacementSwapsTheSuffixAndRecomputesTheCaretInUTF16() throws {
        let base = CotabbyTestFixtures.focusedInputSnapshot(
            precedingText: "Say teh ", trailingText: " now", selection: NSRange(location: 40, length: 0)
        )
        let optimistic = try XCTUnwrap(SpeculativeAcceptanceContext.optimisticSnapshot(
            after: base, replacing: TypoCorrectionReplacement(deletingUTF16Count: 4, replacementText: "the 🐈 ")
        ))

        XCTAssertEqual(optimistic.precedingText, "Say the 🐈 ")
        // 40 - 4 deleted + 7 inserted units ("the " is 4, the emoji is 2, the space is 1).
        XCTAssertEqual(optimistic.selection, NSRange(location: 43, length: 0))
        XCTAssertEqual(optimistic.trailingText, " now")
        XCTAssertEqual(optimistic.elementIdentifier, base.elementIdentifier)
    }

    func testReplacementFailsClosedWhenTheDeletionReachesPastTheReportedCaret() {
        // AX can report a caret location smaller than the captured prefix; a delete longer than that
        // location cannot describe an edit the insertion boundary can actually make.
        let base = CotabbyTestFixtures.focusedInputSnapshot(
            precedingText: "Say teh ", selection: NSRange(location: 3, length: 0)
        )
        XCTAssertNil(SpeculativeAcceptanceContext.optimisticSnapshot(
            after: base, replacing: TypoCorrectionReplacement(deletingUTF16Count: 4, replacementText: "the ")
        ))
    }

    func testSignatureDiffersWhenHostTransformedTheText() {
        let base = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
        let optimistic = SpeculativeAcceptanceContext.optimisticSnapshot(after: base, inserting: " world")
        let autocorrected = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello World")
        XCTAssertNotEqual(optimistic.contentSignature, autocorrected.contentSignature)
    }
}
