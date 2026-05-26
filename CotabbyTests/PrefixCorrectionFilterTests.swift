import XCTest
@testable import Cotabby

final class PrefixCorrectionFilterTests: XCTestCase {

    // MARK: - Identity short-circuit

    func test_identicalText_returnsNil() {
        XCTAssertNil(PrefixCorrectionFilter.acceptedCorrection(
            original: "the quick brown fox",
            proposed: "the quick brown fox"
        ))
    }

    // MARK: - Accepted typo fixes

    func test_singleWordTypo_isAccepted() {
        XCTAssertEqual(
            PrefixCorrectionFilter.acceptedCorrection(original: "teh", proposed: "the"),
            "the"
        )
    }

    func test_multiWordPrefix_singleTypoFix_isAccepted() {
        XCTAssertEqual(
            PrefixCorrectionFilter.acceptedCorrection(
                original: "teh quick brown fox",
                proposed: "the quick brown fox"
            ),
            "the quick brown fox"
        )
    }

    func test_multipleTypoFixes_isAccepted() {
        XCTAssertEqual(
            PrefixCorrectionFilter.acceptedCorrection(
                original: "teh quick brwn fox",
                proposed: "the quick brown fox"
            ),
            "the quick brown fox"
        )
    }

    func test_longerWordTypo_isAccepted() {
        XCTAssertEqual(
            PrefixCorrectionFilter.acceptedCorrection(
                original: "definately yes",
                proposed: "definitely yes"
            ),
            "definitely yes"
        )
    }

    func test_capitalizedTypoPreservingShape_isAccepted() {
        XCTAssertEqual(
            PrefixCorrectionFilter.acceptedCorrection(original: "Helo", proposed: "Hello"),
            "Hello"
        )
    }

    func test_allUppercaseTypoPreservingShape_isAccepted() {
        XCTAssertEqual(
            PrefixCorrectionFilter.acceptedCorrection(original: "TEH", proposed: "THE"),
            "THE"
        )
    }

    // MARK: - Rejected: structural changes

    func test_addedWord_isRejected() {
        XCTAssertNil(PrefixCorrectionFilter.acceptedCorrection(
            original: "the quick fox",
            proposed: "the quick brown fox"
        ))
    }

    func test_removedWord_isRejected() {
        XCTAssertNil(PrefixCorrectionFilter.acceptedCorrection(
            original: "the the quick fox",
            proposed: "the quick fox"
        ))
    }

    func test_addedTrailingPunctuation_isRejected() {
        XCTAssertNil(PrefixCorrectionFilter.acceptedCorrection(
            original: "the quick fox",
            proposed: "the quick fox."
        ))
    }

    func test_changedSeparator_isRejected() {
        // Model "fixed" comma to comma+space.
        XCTAssertNil(PrefixCorrectionFilter.acceptedCorrection(
            original: "hello,world",
            proposed: "hello, world"
        ))
    }

    func test_collapsedWhitespace_isRejected() {
        XCTAssertNil(PrefixCorrectionFilter.acceptedCorrection(
            original: "hello  world",
            proposed: "hello world"
        ))
    }

    // MARK: - Rejected: case changes

    func test_capitalizationAdded_isRejected() {
        // Model promoted lowercase start to capital — rewriting voice, not fixing a typo.
        XCTAssertNil(PrefixCorrectionFilter.acceptedCorrection(
            original: "the quick fox",
            proposed: "The quick fox"
        ))
    }

    func test_caseShapeMismatch_isRejected() {
        XCTAssertNil(PrefixCorrectionFilter.acceptedCorrection(
            original: "teh",
            proposed: "The"
        ))
    }

    // MARK: - Rejected: too-short words

    func test_twoCharWordChange_isRejected() {
        // "im" → "I'm" would also fail on separators, but a pure two-char change is itself rejected.
        XCTAssertNil(PrefixCorrectionFilter.acceptedCorrection(
            original: "im here",
            proposed: "is here"
        ))
    }

    func test_singleCharWordChange_isRejected() {
        XCTAssertNil(PrefixCorrectionFilter.acceptedCorrection(
            original: "i am",
            proposed: "a am"
        ))
    }

    // MARK: - Rejected: edit distance too large

    func test_wordReplacedWithUnrelatedWord_isRejected() {
        XCTAssertNil(PrefixCorrectionFilter.acceptedCorrection(
            original: "the cat sat",
            proposed: "the dog sat"
        ))
    }

    func test_donutToDoughnut_isRejected() {
        // Real word change, not a typo. Distance 3, threshold = max(2, max(5,8)/3) = 2.
        XCTAssertNil(PrefixCorrectionFilter.acceptedCorrection(
            original: "donut shop",
            proposed: "doughnut shop"
        ))
    }

    // MARK: - Mixed scenarios

    func test_typoFixSurroundedByPunctuation_isAccepted() {
        XCTAssertEqual(
            PrefixCorrectionFilter.acceptedCorrection(
                original: "Hello, teh world!",
                proposed: "Hello, the world!"
            ),
            "Hello, the world!"
        )
    }

    func test_typoFixWithNewlines_isAccepted() {
        XCTAssertEqual(
            PrefixCorrectionFilter.acceptedCorrection(
                original: "first line\nteh second",
                proposed: "first line\nthe second"
            ),
            "first line\nthe second"
        )
    }

    func test_emptyStrings_returnNil() {
        XCTAssertNil(PrefixCorrectionFilter.acceptedCorrection(original: "", proposed: ""))
    }

    func test_emptyToNonEmpty_isRejected() {
        // Token counts differ (0 vs 1).
        XCTAssertNil(PrefixCorrectionFilter.acceptedCorrection(original: "", proposed: "hello"))
    }
}
