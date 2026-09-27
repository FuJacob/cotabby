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
        // 2^(3^2) = 512; a left-associative parser would produce (2^3)^2 = 64.
        XCTAssertEqual(sut.evaluate("2^3^2")?.previewText, "= 512")
    }

    func test_multiplicationBindsTighterThanAddition() {
        XCTAssertEqual(sut.evaluate("2+3*4")?.insertionText, "14")
        XCTAssertEqual(sut.evaluate("10-4-3")?.insertionText, "3")
    }

    func test_unicodeAndUppercaseOperatorAliases() {
        XCTAssertEqual(sut.evaluate("3×4")?.insertionText, "12")
        XCTAssertEqual(sut.evaluate("3X4")?.insertionText, "12")
        XCTAssertEqual(sut.evaluate("10÷4")?.insertionText, "2.5")
    }

    func test_unaryMinusInsideAnExpressionIsAllowed() {
        // Only a *lone* signed number is rejected; once a binary operator appears it is an expression.
        XCTAssertEqual(sut.evaluate("-5+3")?.previewText, "= -2")
        XCTAssertEqual(sut.evaluate("2*-3")?.insertionText, "-6")
    }

    func test_whitespaceIsIgnored() {
        XCTAssertEqual(sut.evaluate("( 2 + 3 ) * 4")?.insertionText, "20")
    }

    func test_percentAloneCountsAsAnOperator() {
        XCTAssertEqual(sut.evaluate("50%")?.insertionText, "0.5")
    }

    func test_floatingPointNoiseIsTrimmedBySignificantDigits() {
        XCTAssertEqual(sut.evaluate("0.1+0.2")?.insertionText, "0.3")
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
        XCTAssertNil(sut.evaluate("2+3)"))
    }

    func test_nonNumericTokens_returnNil() {
        for query in ["abc+1", "1e5+1", "1.2.3+1", "=", "5++"] {
            XCTAssertNil(sut.evaluate(query), query)
        }
    }

    // MARK: - format

    func test_format_integersDropTheDecimalPointBelowTheInt64SafeRange() {
        XCTAssertEqual(ArithmeticEvaluator.format(3), "3")
        XCTAssertEqual(ArithmeticEvaluator.format(-2.5), "-2.5")
        // At 1e15 and above the integer path is skipped, so huge values fall back to %g notation.
        XCTAssertEqual(ArithmeticEvaluator.format(1e15), "1e+15")
    }

    func test_format_rejectsNonFiniteValues() {
        XCTAssertNil(ArithmeticEvaluator.format(.infinity))
        XCTAssertNil(ArithmeticEvaluator.format(.nan))
    }
}
