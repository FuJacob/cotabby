import XCTest
@testable import Cotabby

/// Tests for the pure end-of-line classifier that gates mid-line completion strategies.
///
/// The key distinction these lock down: a caret can have non-empty `trailingText` (a line break and
/// later paragraphs) while still being at the end of its own line. Fill-in-middle must treat that as
/// end-of-line, not as mid-line infilling.
final class CaretLinePositionTests: XCTestCase {
    func test_emptyTrailingTextIsEndOfLine() {
        XCTAssertTrue(CaretLinePosition.isAtEndOfLine(trailingText: ""))
    }

    func test_leadingNewlineIsEndOfLine() {
        // Caret sits at line end; the next paragraph follows after the break.
        XCTAssertTrue(CaretLinePosition.isAtEndOfLine(trailingText: "\nnext paragraph"))
    }

    func test_whitespaceThenNewlineIsEndOfLine() {
        XCTAssertTrue(CaretLinePosition.isAtEndOfLine(trailingText: "   \nmore"))
    }

    func test_trailingWhitespaceOnlyIsEndOfLine() {
        XCTAssertTrue(CaretLinePosition.isAtEndOfLine(trailingText: "   "))
    }

    func test_sameLineTextIsNotEndOfLine() {
        XCTAssertFalse(CaretLinePosition.isAtEndOfLine(trailingText: " world"))
    }

    func test_singleNonWhitespaceCharacterIsNotEndOfLine() {
        XCTAssertFalse(CaretLinePosition.isAtEndOfLine(trailingText: ")"))
    }

    func test_whitespaceThenSameLineTextIsNotEndOfLine() {
        // Whitespace before real same-line text still means the caret is mid-line.
        XCTAssertFalse(CaretLinePosition.isAtEndOfLine(trailingText: "  rest of line\n"))
    }

    func test_focusedInputContextExposesSignal() {
        let midLine = CotabbyTestFixtures.suggestionRequest(trailingText: " rest of line")
        XCTAssertFalse(midLine.context.isCaretAtEndOfLine)

        let endOfLine = CotabbyTestFixtures.suggestionRequest(trailingText: "\nnext paragraph")
        XCTAssertTrue(endOfLine.context.isCaretAtEndOfLine)
    }
}
