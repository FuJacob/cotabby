import AppKit
import XCTest
@testable import Cotabby

/// Claude's Code composer (2026-09-11): the first letter of a message was in the value while the
/// text-marker caret still sat at the empty paragraph's start, x 342 on a line from 342, 677pt wide.
final class CaretLagPolicyTests: XCTestCase {
    private let font = NSFont.systemFont(ofSize: 15)

    private func lags(_ text: String, caretX: CGFloat, rightToLeft: Bool = false) -> Bool {
        CaretLagPolicy.caretLagsTypedText(
            caretX: caretX, line: CGRect(x: 342, y: 0, width: 677, height: 20), textBeforeCaretOnLine: text, font: font,
            isRightToLeft: rightToLeft
        )
    }

    func testACaretStillAtTheLineStartBehindATypedLetterLags() {
        XCTAssertTrue(lags("K", caretX: 342))
        XCTAssertTrue(lags("Keep", caretX: 342.5))
    }

    func testACaretAfterTheTextDoesNotLag() {
        XCTAssertFalse(lags("K", caretX: 351))
        XCTAssertFalse(lags("Keep", caretX: 375))
    }

    /// An empty line's caret belongs at its start, and a leading space decides nothing (some hosts
    /// collapse it).
    func testAnEmptyOrWhitespaceLineDecidesNothing() {
        XCTAssertFalse(lags("", caretX: 342))
        XCTAssertFalse(lags("  ", caretX: 342))
    }

    /// Text long enough to have wrapped can put the caret at a visual line's start legitimately.
    func testTextThatMayHaveWrappedIsNotJudged() {
        let long = String(repeating: "a long line of words ", count: 8)
        XCTAssertFalse(lags(long, caretX: 342))
    }

    func testRightToLeftIsNotJudged() {
        XCTAssertFalse(lags("K", caretX: 342, rightToLeft: true))
    }
}
