import XCTest
@testable import Cotabby

/// Verifies `MarkerSelectionSynthesizer`, which turns the three caret-adjacent text fragments read
/// from a Chromium/WebKit contenteditable's text markers into a caret-windowed `NSRange` selection.
/// The invariant under test: `selection` always indexes correctly into the (windowed) `text`, so
/// the rest of the focus pipeline can split before/after-caret context without a document offset.
final class MarkerSelectionSynthesizerTests: XCTestCase {
    func testCaretInMiddleProducesZeroLengthSelectionAtBeforeLength() {
        let result = MarkerSelectionSynthesizer.make(
            beforeCaret: "Hello ", selected: "", afterCaret: "world")

        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.selection, NSRange(location: 6, length: 0))
    }

    func testCaretAtStart() {
        let result = MarkerSelectionSynthesizer.make(
            beforeCaret: "", selected: "", afterCaret: "abc")

        XCTAssertEqual(result.text, "abc")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 0))
    }

    func testNonEmptySelectionLengthAndLocation() {
        let result = MarkerSelectionSynthesizer.make(
            beforeCaret: "Hi ", selected: "there", afterCaret: "!")

        XCTAssertEqual(result.text, "Hi there!")
        XCTAssertEqual(result.selection, NSRange(location: 3, length: 5))
        // The selected substring must be exactly what selection points at.
        XCTAssertEqual((result.text as NSString).substring(with: result.selection), "there")
    }

    func testWindowingKeepsCaretAdjacentTextAndKeepsSelectionConsistent() {
        let result = MarkerSelectionSynthesizer.make(
            beforeCaret: "ABCDEFG", selected: "X", afterCaret: "HIJKLM", window: 3)

        // Before is windowed to its last 3 units, after to its first 3.
        XCTAssertEqual(result.text, "EFGXHIJ")
        XCTAssertEqual(result.selection, NSRange(location: 3, length: 1))
        XCTAssertEqual((result.text as NSString).substring(with: result.selection), "X")
    }

    func testWindowDoesNotSplitSurrogatePairs() {
        // Each emoji is 2 UTF-16 units. A window of 3 lands mid-emoji; we widen to a
        // composed-character boundary, so the kept slice is whole emoji, not an orphaned surrogate.
        let result = MarkerSelectionSynthesizer.make(
            beforeCaret: "😀😀😀", selected: "", afterCaret: "", window: 3)

        // Every kept scalar is a full emoji (no U+FFFD from a split pair), and the caret location
        // is the UTF-16 length of the widened before-window.
        XCTAssertFalse(result.text.unicodeScalars.contains("\u{FFFD}"))
        XCTAssertTrue(result.text.allSatisfy { $0 == "😀" })
        XCTAssertEqual(result.selection.location, (result.text as NSString).length)
        XCTAssertEqual(result.selection.length, 0)
    }

    func testShorterThanWindowIsUnchanged() {
        let result = MarkerSelectionSynthesizer.make(
            beforeCaret: "ab", selected: "", afterCaret: "cd", window: 100)

        XCTAssertEqual(result.text, "abcd")
        XCTAssertEqual(result.selection, NSRange(location: 2, length: 0))
    }
}
