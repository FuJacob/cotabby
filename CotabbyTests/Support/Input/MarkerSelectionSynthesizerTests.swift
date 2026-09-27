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
        // Each emoji is 2 UTF-16 units. A window of 3 lands mid-emoji on both sides; the slice is
        // widened outward to whole composed characters (so it can exceed the window by one unit)
        // rather than keeping an orphaned surrogate.
        let result = MarkerSelectionSynthesizer.make(
            beforeCaret: "😀😀😀", selected: "", afterCaret: "🐱🐱🐱", window: 3)

        XCTAssertEqual(result.text, "😀😀🐱🐱")
        XCTAssertEqual(result.selection, NSRange(location: 4, length: 0))
    }

    func testSelectedTextIsNeverWindowed() {
        // Only the context on either side is bounded; the selection itself must survive whole so
        // the replacement range still covers everything the user highlighted.
        let result = MarkerSelectionSynthesizer.make(
            beforeCaret: "abc", selected: "SELECTED", afterCaret: "xyz", window: 1)

        XCTAssertEqual(result.text, "cSELECTEDx")
        XCTAssertEqual(result.selection, NSRange(location: 1, length: 8))
    }

    func testTextExactlyAtTheWindowIsUnchanged() {
        let result = MarkerSelectionSynthesizer.make(
            beforeCaret: "abc", selected: "", afterCaret: "def", window: 3)

        XCTAssertEqual(result.text, "abcdef")
        XCTAssertEqual(result.selection, NSRange(location: 3, length: 0))
    }

    func testShorterThanWindowIsUnchanged() {
        let result = MarkerSelectionSynthesizer.make(
            beforeCaret: "ab", selected: "", afterCaret: "cd", window: 100)

        XCTAssertEqual(result.text, "abcd")
        XCTAssertEqual(result.selection, NSRange(location: 2, length: 0))
    }

    func testMailSpaceNormalizationPreservesUTF16SelectionAndOtherWhitespace() {
        let result = MarkerSelectionSynthesizer.make(
            beforeCaret: "😀Hello\u{00A0}", selected: "a\u{00A0}b", afterCaret: "\t\nnext\u{00A0}word",
            normalizeNonBreakingSpaces: true
        )
        XCTAssertEqual(result.text, "😀Hello a b\t\nnext word")
        XCTAssertEqual(result.selection, NSRange(location: 8, length: 3))
        XCTAssertEqual((result.text as NSString).substring(with: result.selection), "a b")
    }

    func testOtherHostsPreserveIntentionalNonBreakingSpaces() {
        let result = MarkerSelectionSynthesizer.make(
            beforeCaret: "Hello\u{00A0}", selected: "", afterCaret: "world"
        )
        XCTAssertEqual(result.text, "Hello\u{00A0}world")
    }
}
