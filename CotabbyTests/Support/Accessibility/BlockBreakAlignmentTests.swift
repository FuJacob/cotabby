import XCTest
@testable import Cotabby

/// Each case is a shape measured in Chrome (a ProseMirror page modelled on Claude's composer, 2026-09-11):
/// the field's value, its range text before the caret, and where the caret belongs in the value.
final class BlockBreakAlignmentTests: XCTestCase {
    private func caret(
        value: String, rangePrefix: String, startsBlock: Bool = false, asked: UnsafeMutablePointer<Int>? = nil
    ) -> Int? {
        BlockBreakAlignment.split(value: value, rangePrefix: rangePrefix, rangeSelected: "") {
            asked?.pointee += 1
            return startsBlock
        }?.selection.location
    }

    func testTheValueKeepsTheBreakTheRangeTextLeavesOutBetweenParagraphs() {
        // Shift+Return then Return: the range text keeps the first break and drops the second.
        XCTAssertEqual(caret(value: "abc\ndef\nghi", rangePrefix: "abc\ndefghi"), 11)
        XCTAssertEqual(caret(value: "First paragraph ends here.\nSecond", rangePrefix: "First paragraph ends here.Se"), 29)
    }

    func testListMarkersAreTextInBothAndOnlyTheBreaksAreLeftOut() {
        let value = "Things:\n• SPACE HANDLING\n• Font size"
        XCTAssertEqual(caret(value: value, rangePrefix: "Things:• SPACE HANDLING• Fo"), 29)
    }

    func testABlockEndAndTheNextBlockStartShareARangeOffsetAndTheHostDecides() {
        let value = "First paragraph ends here.\nSecond line"
        XCTAssertEqual(caret(value: value, rangePrefix: "First paragraph ends here.", startsBlock: false), 26)
        XCTAssertEqual(caret(value: value, rangePrefix: "First paragraph ends here.", startsBlock: true), 27)
    }

    /// An empty paragraph after the caret's: the range text keeps its break too, and the caret the
    /// host reports sits before it.
    func testACaretInAnEmptyLastParagraphGoesAfterTheBreak() {
        XCTAssertEqual(caret(value: "First paragraph ends here.\n", rangePrefix: "First paragraph ends here.", startsBlock: true), 27)
    }

    func testTheHostIsAskedOnlyWhenABreakFollowsTheCaret() {
        var asked = 0
        XCTAssertEqual(caret(value: "abc\ndef\nghi", rangePrefix: "abc\nde", startsBlock: true, asked: &asked), 6)
        XCTAssertEqual(caret(value: "abc", rangePrefix: "abc", startsBlock: true, asked: &asked), 3)
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(caret(value: "abc\ndef", rangePrefix: "abc", startsBlock: false, asked: &asked), 3)
        XCTAssertEqual(asked, 1)
    }

    func testAHardBreakAtTheCaretStaysBeforeTheCaretWhenTheHostKeepsIt() {
        // "abc|\ndef" with the caret at the end of the line before a Shift+Return break.
        XCTAssertEqual(caret(value: "abc\ndef", rangePrefix: "abc", startsBlock: false), 3)
        XCTAssertEqual(caret(value: "abc\ndef", rangePrefix: "abc\n"), 4)
    }

    func testTextsThatDifferInAnythingButBreaksDoNotAlign() {
        XCTAssertNil(caret(value: "abc", rangePrefix: "abd"))
        XCTAssertNil(caret(value: "abc", rangePrefix: "abcd"))
        XCTAssertNil(caret(value: "ab\u{FFFC}c", rangePrefix: "abc"))
    }

    func testASelectionStartsAtItsFirstCharacter() {
        let split = BlockBreakAlignment.split(value: "abc\ndef", rangePrefix: "abc", rangeSelected: "de") { XCTFail("not asked"); return true }
        XCTAssertEqual(split?.selection, NSRange(location: 4, length: 2))
        XCTAssertEqual(split?.text, "abc\ndef")
    }

    func testEmptyInputs() {
        XCTAssertEqual(caret(value: "", rangePrefix: ""), 0)
        XCTAssertEqual(caret(value: "\nabc", rangePrefix: "", startsBlock: true), 1)
        XCTAssertEqual(BlockBreakAlignment.valueOffset(following: "", in: "abc"), 0)
    }
}
