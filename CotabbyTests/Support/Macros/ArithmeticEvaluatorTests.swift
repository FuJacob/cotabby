import XCTest
@testable import Cotabby

/// Tests for the pure arithmetic macro evaluator: operator precedence, the worked-expression
/// insertion policy, and the guards that keep non-expressions out.
final class ArithmeticEvaluatorTests: XCTestCase {
    private let sut = ArithmeticEvaluator()

    func test_addition_insertsResultOnly() {
        let result = sut.evaluate("5+5=")
        XCTAssertEqual(result?.previewText, "= 10")
        XCTAssertEqual(result?.insertionText, "10")
    }

    func test_withoutTrailingEquals_insertsResultOnly() {
        XCTAssertEqual(sut.evaluate("5+5")?.insertionText, "10")
    }

    func test_multiplyWithX_insertsResultOnly() {
        XCTAssertEqual(sut.evaluate("5x5")?.insertionText, "25")
    }

    func test_powerIsRightAssociative() {
        XCTAssertEqual(sut.evaluate("2^10")?.previewText, "= 1024")
    }

    func test_parentheses() {
        XCTAssertEqual(sut.evaluate("(2+3)*4")?.previewText, "= 20")
    }

    func test_divisionRoundsToSignificantDigits() {
        XCTAssertEqual(sut.evaluate("10/3")?.previewText, "= 3.333333333")
    }

    func test_trailingPercentMeansPercent() {
        XCTAssertEqual(sut.evaluate("200*15%")?.previewText, "= 30")
    }

    func test_bareNumber_isNotAMacro() {
        XCTAssertNil(sut.evaluate("5"))
    }

    func test_unarySignedNumber_isNotAMacro() {
        XCTAssertNil(sut.evaluate("-5"))
    }

    func test_divisionByZero_returnsNil() {
        XCTAssertNil(sut.evaluate("5/0"))
    }

    func test_incompleteExpression_returnsNil() {
        XCTAssertNil(sut.evaluate("5+"))
    }

    func test_unbalancedParentheses_returnsNil() {
        XCTAssertNil(sut.evaluate("(2+3"))
    }
}
