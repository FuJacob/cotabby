import AppKit
import XCTest
@testable import Cotabby

final class GhostCaretRefinementTests: XCTestCase {
    private let helvetica = NSFont(name: "Helvetica", size: 16)!

    /// Safari, Helvetica 16px input: content edge 265, text "Field two alpha bravo charlie x" advances
    /// 216.1pt, AX reported the caret at 482. The refined caret lands on the true 481.1.
    func testRefinesARoundedWebCaretFromTheLineEdgeAndTextAdvance() {
        let text = "Field two alpha bravo charlie x"
        let advance = (text as NSString).size(withAttributes: [.font: helvetica]).width
        let refined = GhostCaretRefinement.caretX(
            GhostCaretRefinement.Input(lineLeft: 265, paragraphTextBeforeCaret: text, font: helvetica, reportedCaretX: 482, isRightToLeft: false)
        )
        XCTAssertEqual(refined ?? -1, 265 + advance, accuracy: 0.001)
        XCTAssertEqual(refined ?? -1, 481.1, accuracy: 0.6)
    }

    func testDisagreementBeyondRoundingIsRejected() {
        // A soft-wrapped paragraph: the paragraph text is far longer than the visual line.
        let wrapped = String(repeating: "alpha bravo charlie ", count: 6) + "x"
        XCTAssertNil(GhostCaretRefinement.caretX(
            GhostCaretRefinement.Input(lineLeft: 265, paragraphTextBeforeCaret: wrapped, font: helvetica, reportedCaretX: 482, isRightToLeft: false)
        ))
    }

    func testEmptyLineAndRightToLeftAreLeftToTheHost() {
        XCTAssertNil(GhostCaretRefinement.caretX(
            GhostCaretRefinement.Input(lineLeft: 265, paragraphTextBeforeCaret: "", font: helvetica, reportedCaretX: 265, isRightToLeft: false)
        ))
        XCTAssertNil(GhostCaretRefinement.caretX(
            GhostCaretRefinement.Input(lineLeft: 265, paragraphTextBeforeCaret: "abc", font: helvetica, reportedCaretX: 290, isRightToLeft: true)
        ))
    }

    func testParagraphTextStopsAtTheLastHardBreak() {
        XCTAssertEqual(GhostCaretRefinement.paragraphTextBeforeCaret(in: "first line\nsecond x"), "second x")
        XCTAssertEqual(GhostCaretRefinement.paragraphTextBeforeCaret(in: "no breaks"), "no breaks")
    }
}
