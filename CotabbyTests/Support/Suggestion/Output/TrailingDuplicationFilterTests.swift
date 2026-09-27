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

    func test_justBelowHalfOfCompletion_isNotDuplicate() {
        // Same six-character shared run as above, but "theywenthomely" folds to 14 characters, so
        // Shape 3 needs 7. This pins the half-length threshold from the other side.
        XCTAssertFalse(
            TrailingDuplicationFilter.duplicatesTrailingText("they went homely", trailingText: "they were here")
        )
    }

    func test_completionContainingAShortSuffix_isNotDuplicate() {
        // Shape 2 needs the folded suffix itself to reach the overlap floor: a two-character
        // trailing "ab" is too common a stem to prove the completion re-emits it.
        XCTAssertFalse(
            TrailingDuplicationFilter.duplicatesTrailingText("abcdef", trailingText: "ab")
        )
    }

    func test_floorAppliesToFoldedLength_notRawLength() {
        // The raw completion is long, but only one alphanumeric survives folding.
        XCTAssertFalse(
            TrailingDuplicationFilter.duplicatesTrailingText("** - a!", trailingText: "a b c d")
        )
        // A punctuation-only suffix folds to nothing, so there is nothing to duplicate.
        XCTAssertFalse(
            TrailingDuplicationFilter.duplicatesTrailingText("hello world", trailingText: "... !!")
        )
    }

    func test_cjkDuplication_isDetected() {
        // Ideographs and kana are alphanumerics, so scripts without spaces fold and compare too.
        XCTAssertTrue(
            TrailingDuplicationFilter.duplicatesTrailingText("良い天気", trailingText: "良い天気ですね")
        )
    }
}
