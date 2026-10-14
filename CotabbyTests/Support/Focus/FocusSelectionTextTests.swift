import XCTest
@testable import Cotabby

/// The selected text is cut from the same bounded window the snapshot's preceding and trailing text
/// come from, so the three always describe one consistent read.
final class FocusSelectionTextTests: XCTestCase {
    func test_extractsTheSelectedRange() {
        XCTAssertEqual(
            FocusSelectionText.extract(windowText: "Dear Charlie, I brought you", windowSelection: NSRange(location: 5, length: 7)),
            "Charlie"
        )
    }

    func test_emptySelectionIsEmptyText() {
        XCTAssertEqual(FocusSelectionText.extract(windowText: "Hello", windowSelection: NSRange(location: 5, length: 0)), "")
    }

    func test_rangePastTheEndIsClamped() {
        XCTAssertEqual(FocusSelectionText.extract(windowText: "Hello", windowSelection: NSRange(location: 3, length: 10)), "lo")
        XCTAssertEqual(FocusSelectionText.extract(windowText: "Hello", windowSelection: NSRange(location: 9, length: 2)), "")
    }

    func test_composedCharactersStayWhole() {
        // An emoji is two UTF-16 units; a range that splits it must not produce half a character.
        let text = "Hi 👋 there"
        XCTAssertEqual(FocusSelectionText.extract(windowText: text, windowSelection: NSRange(location: 3, length: 1)), "👋")
    }
}
