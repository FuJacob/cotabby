import XCTest
@testable import Cotabby

/// Pure-function tests for the last-mile insertion safety gate.
final class InsertionSafetyGateTests: XCTestCase {

    func test_normalText_isSafe() {
        XCTAssertTrue(InsertionSafetyGate.isSafeToInsert("hello there"))
    }

    func test_loneStructuralPunctuation_isSafe() {
        // Closing a bracket or ending a sentence is a legitimate inline completion.
        XCTAssertTrue(InsertionSafetyGate.isSafeToInsert(")"))
        XCTAssertTrue(InsertionSafetyGate.isSafeToInsert("."))
    }

    func test_empty_isUnsafe() {
        XCTAssertFalse(InsertionSafetyGate.isSafeToInsert(""))
    }

    func test_whitespaceOnly_isUnsafe() {
        XCTAssertFalse(InsertionSafetyGate.isSafeToInsert("   "))
    }

    func test_replacementCharacter_isUnsafe() {
        XCTAssertFalse(InsertionSafetyGate.isSafeToInsert("ab\u{FFFD}cd"))
    }

    func test_interiorControlCharacter_isUnsafe() {
        XCTAssertFalse(InsertionSafetyGate.isSafeToInsert("a\tb"))
    }

    func test_multiLineContent_isSafe() {
        // A line feed is legitimate content in a multi-line completion, so it must pass (the previous
        // behavior rejected it, silently suppressing every multi-line completion).
        XCTAssertTrue(InsertionSafetyGate.isSafeToInsert("first line\nsecond line"))
    }

    func test_newlineOnly_isUnsafe() {
        // Newlines are whitespace; a newline-only completion is still nothing worth inserting.
        XCTAssertFalse(InsertionSafetyGate.isSafeToInsert("\n\n"))
    }
}
