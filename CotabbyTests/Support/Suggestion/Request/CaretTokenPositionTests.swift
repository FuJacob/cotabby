import XCTest
@testable import Cotabby

final class CaretTokenPositionTests: XCTestCase {
    func testCaretInsideWordsNumbersAndAddressesIsInsideToken() {
        // The eval's dup-trailing negatives, all of which showed a duplicate before this rule.
        XCTAssertTrue(CaretTokenPosition.isInsideToken(precedingText: "Packing list: passport, charger, head", trailingText: "phones, sunscreen"))
        XCTAssertTrue(CaretTokenPosition.isInsideToken(precedingText: "The meeting is at 3", trailingText: ":30 tomorrow"))
        XCTAssertTrue(CaretTokenPosition.isInsideToken(precedingText: "Please send the report to jane", trailingText: "@example.com before"))
        XCTAssertTrue(CaretTokenPosition.isInsideToken(precedingText: "const total = items.red", trailingText: "uce((sum, item)"))
        XCTAssertTrue(CaretTokenPosition.isInsideToken(precedingText: "Our office is located at 41", trailingText: "5 Mission Street"))
        XCTAssertTrue(CaretTokenPosition.isInsideToken(precedingText: "snake", trailingText: "_case"))
    }

    func testCaretAtWordEndOrBeforePunctuationIsNotInsideToken() {
        XCTAssertFalse(CaretTokenPosition.isInsideToken(precedingText: "Thanks for your patience", trailingText: " while we sorted"))
        XCTAssertFalse(CaretTokenPosition.isInsideToken(precedingText: "Thanks", trailingText: "."))
        XCTAssertFalse(CaretTokenPosition.isInsideToken(precedingText: "Thanks", trailingText: ". Next sentence"))
        XCTAssertFalse(CaretTokenPosition.isInsideToken(precedingText: "Thanks", trailingText: ""))
        XCTAssertFalse(CaretTokenPosition.isInsideToken(precedingText: "Hello ", trailingText: "world"))
        XCTAssertFalse(CaretTokenPosition.isInsideToken(precedingText: "at 3", trailingText: ": later"))
    }
}
