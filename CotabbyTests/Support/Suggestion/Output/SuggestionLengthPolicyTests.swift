import XCTest
@testable import Cotabby

final class SuggestionLengthPolicyTests: XCTestCase {
    func testTextWithinTheWindowIsUntouched() {
        XCTAssertEqual(SuggestionLengthPolicy.trimmed(" for your help.", minimum: 4, maximum: 7), " for your help.")
        XCTAssertEqual(SuggestionLengthPolicy.trimmed(" one two three four five six seven", minimum: 4, maximum: 7), " one two three four five six seven")
    }

    func testTextPastTheMaximumIsCutAtAWordBoundary() {
        XCTAssertEqual(
            SuggestionLengthPolicy.trimmed(" I've been thinking about this for a while now", minimum: 4, maximum: 7),
            " I've been thinking about this for a"
        )
    }

    func testAClauseBoundaryInsideTheWindowIsPreferred() {
        // "…later today," ends the fifth word: a natural pause inside 4...7 beats a hard cut at 7.
        XCTAssertEqual(
            SuggestionLengthPolicy.trimmed(" and I will send it later today, once the numbers are in", minimum: 4, maximum: 7),
            " and I will send it later today,"
        )
    }

    func testAClauseBoundaryBeforeTheMinimumIsIgnored() {
        XCTAssertEqual(
            SuggestionLengthPolicy.trimmed(" yes, and the rest of the report is ready now", minimum: 4, maximum: 7),
            " yes, and the rest of the report"
        )
    }

    func testLeadingWhitespaceSurvives() {
        XCTAssertEqual(SuggestionLengthPolicy.trimmed(" a b c d e f g h", minimum: 2, maximum: 4), " a b c d")
    }
}
