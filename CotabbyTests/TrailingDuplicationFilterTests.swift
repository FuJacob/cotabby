import XCTest
@testable import Cotabby

/// Pure-function tests for the after-caret duplication guard. No mocks or I/O: the same inputs
/// always produce the same verdict, so every assertion is deterministic.
final class TrailingDuplicationFilterTests: XCTestCase {

    func test_exactPrefixDuplication_isDuplicate() {
        XCTAssertTrue(
            TrailingDuplicationFilter.duplicatesTrailingText("the dog", trailingText: "the dog runs")
        )
    }

    func test_leadingStrayGlyph_stillMatchesAfterFolding() {
        // A markdown bullet or stray punctuation in the raw output must not let a duplicate through.
        XCTAssertTrue(
            TrailingDuplicationFilter.duplicatesTrailingText("**the dog", trailingText: "the dog runs")
        )
    }

    func test_caseInsensitiveDuplication_isDuplicate() {
        XCTAssertTrue(
            TrailingDuplicationFilter.duplicatesTrailingText("The Dog", trailingText: "the dog runs")
        )
    }

    func test_completionContainsWholeSuffix_isDuplicate() {
        XCTAssertTrue(
            TrailingDuplicationFilter.duplicatesTrailingText("ing the cat", trailingText: "ing")
        )
    }

    func test_genuineContinuation_isNotDuplicate() {
        XCTAssertFalse(
            TrailingDuplicationFilter.duplicatesTrailingText("world peace now", trailingText: "domination plans")
        )
    }

    func test_emptyTrailingText_isNotDuplicate() {
        XCTAssertFalse(
            TrailingDuplicationFilter.duplicatesTrailingText("hello world", trailingText: "")
        )
    }

    func test_shortCompletionBelowOverlapFloor_isNotDuplicate() {
        XCTAssertFalse(
            TrailingDuplicationFilter.duplicatesTrailingText("ok", trailingText: "okay then")
        )
    }
}
