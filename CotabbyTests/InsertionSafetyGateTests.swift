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
}
