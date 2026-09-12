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

    /// The continuation prefetch runs on the keystroke that typed through the ghost, before the host
    /// publishes it (2026-09-11): the text after the ghost comes from the session, not from the
    /// snapshot plus the remaining tail, which read "The budget" + "is $100," as "The budgetis $100,".
    func testTheTextOnceTypedThroughIgnoresWhatTheHostHasNotPublished() {
        let session = CotabbyTestFixtures.activeSession(fullText: " is $100,", consumedCharacterCount: 1, basePrecedingText: "The budget")
        XCTAssertEqual(session.remainingText, "is $100,")
        XCTAssertEqual(session.precedingTextOnceTypedThrough, "The budget is $100,")
        let lagging = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "The budget")
        let optimistic = SpeculativeAcceptanceContext.optimisticSnapshot(after: lagging, precedingText: session.precedingTextOnceTypedThrough)
        XCTAssertEqual(optimistic.precedingText, "The budget is $100,")
        XCTAssertEqual(optimistic.selection.location, lagging.selection.location + " is $100,".utf16.count)
        XCTAssertEqual(optimistic.trailingText, lagging.trailingText)
    }

    func testTheSnapshotAlreadyHoldingTypedTextMovesTheCaretByTheRest() {
        let published = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "The budget i")
        let optimistic = SpeculativeAcceptanceContext.optimisticSnapshot(after: published, precedingText: "The budget is $100,")
        XCTAssertEqual(optimistic.selection.location, published.selection.location + "s $100,".utf16.count)
    }
}
