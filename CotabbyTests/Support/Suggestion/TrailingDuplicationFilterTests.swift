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

    func test_longLeadingRunAtHalfOfCompletion_isDuplicate() {
        // Shape 3: neither side is a prefix of the other, but the shared leading run
        // ("they we", folded to 6 alphanumerics) reaches half the completion's folded
        // length (12 / 2 = 6), which is the "model re-emits the next few words" signature.
        XCTAssertTrue(
            TrailingDuplicationFilter.duplicatesTrailingText("they went home", trailingText: "they were here")
        )
    }

    func test_shortSharedLeadingRunBelowHalf_isNotDuplicate() {
        // The shared "the" run (3 folded characters) is well under half of the completion's
        // 17 folded characters, so this is a coincidental stem match, not a duplication.
        XCTAssertFalse(
            TrailingDuplicationFilter.duplicatesTrailingText("the dog barks loudly", trailingText: "the cat")
        )
    }
}
