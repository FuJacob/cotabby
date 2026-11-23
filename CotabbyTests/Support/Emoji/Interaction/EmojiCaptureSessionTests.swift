import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the value that holds one open emoji capture: results and highlight always change
/// together, and the highlight wraps around the ribbon.
@MainActor
final class EmojiCaptureSessionTests: XCTestCase {
    private func match(_ glyph: String, alias: String) -> EmojiMatch {
        EmojiMatch(entry: EmojiEntry(glyph: glyph, name: alias, aliases: [alias], keywords: []))
    }

    private var threeMatches: [EmojiMatch] {
        [match("😄", alias: "smile"), match("😁", alias: "smiley"), match("😊", alias: "blush")]
    }

    private func makeSession() -> EmojiCaptureSession {
        EmojiCaptureSession(focusChangeSequence: 4, caretRect: CGRect(x: 1, y: 2, width: 3, height: 4))
    }

    func test_newSession_isAnEmptyQueryWithNothingSelectable() {
        let session = makeSession()

        XCTAssertEqual(session.focusChangeSequence, 4)
        XCTAssertEqual(session.caretRect, CGRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(session.query, "")
        XCTAssertTrue(session.matches.isEmpty)
        XCTAssertNil(session.selectedMatch)
    }

    func test_setResults_storesQueryAndReturnsTheHighlightToTheBestMatch() {
        var session = makeSession()
        session.setResults(threeMatches, for: "sm")
        XCTAssertTrue(session.moveSelection(.next))
        XCTAssertEqual(session.selectedIndex, 1)

        let narrowed = [match("😁", alias: "smiley")]
        session.setResults(narrowed, for: "smi")

        XCTAssertEqual(session.query, "smi")
        XCTAssertEqual(session.matches, narrowed)
        XCTAssertEqual(session.selectedIndex, 0)
        XCTAssertEqual(session.selectedMatch?.glyph, "😁")
    }

    func test_moveSelection_wrapsAtBothEnds() {
        var session = makeSession()
        session.setResults(threeMatches, for: "s")

        XCTAssertTrue(session.moveSelection(.previous))
        XCTAssertEqual(session.selectedIndex, 2, "previous from the first match wraps to the last")
        XCTAssertTrue(session.moveSelection(.next))
        XCTAssertEqual(session.selectedIndex, 0, "next from the last match wraps to the first")
        XCTAssertTrue(session.moveSelection(.next))
        XCTAssertEqual(session.selectedMatch?.glyph, "😁")
    }

    func test_moveSelection_withoutMatches_reportsNothingMoved() {
        var session = makeSession()

        XCTAssertFalse(session.moveSelection(.next))
        XCTAssertFalse(session.moveSelection(.previous))
        XCTAssertEqual(session.selectedIndex, 0)
    }

    func test_selectIndex_picksAClickedCellAndAnOutOfRangeIndexSelectsNothing() {
        var session = makeSession()
        session.setResults(threeMatches, for: "s")

        session.select(index: 2)
        XCTAssertEqual(session.selectedMatch?.glyph, "😊")

        session.select(index: 3)
        XCTAssertNil(session.selectedMatch)
        session.select(index: -1)
        XCTAssertNil(session.selectedMatch)
    }

    func test_caretRect_canFollowTheCaretWithoutDisturbingResults() {
        var session = makeSession()
        session.setResults(threeMatches, for: "s")
        XCTAssertTrue(session.moveSelection(.next))

        session.caretRect = CGRect(x: 50, y: 60, width: 2, height: 18)

        XCTAssertEqual(session.caretRect, CGRect(x: 50, y: 60, width: 2, height: 18))
        XCTAssertEqual(session.selectedIndex, 1)
        XCTAssertEqual(session.query, "s")
    }
}
