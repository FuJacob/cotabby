import XCTest
@testable import Cotabby

/// Focused coverage for one responsibility of `SuggestionSessionReconciler`.
final class SuggestionWordAcceptanceTests: XCTestCase {
    func test_nextAcceptanceChunk_includesLeadingWhitespaceAndNextVisibleToken() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptanceChunk(from: "  world again"),
            "  world"
        )
    }

    func test_nextAcceptanceChunk_returnsSingleTokenWhenNoLeadingWhitespace() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptanceChunk(from: "world again"),
            "world"
        )
    }

    func test_nextAcceptanceChunk_returnsEmptyForEmptyTail() {
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptanceChunk(from: ""), "")
    }

    func test_nextAcceptanceChunk_defaultsToAcceptingTrailingPunctuation() {
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptanceChunk(from: "you?"), "you?")
    }

    func test_nextAcceptanceChunk_keepsTrailingPunctuationWhenAutoAcceptEnabled() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptanceChunk(from: "you?", autoAcceptTrailingPunctuation: true),
            "you?"
        )
    }

    func test_nextAcceptanceChunk_splitsTrailingPunctuationWhenAutoAcceptDisabled() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptanceChunk(from: "you?", autoAcceptTrailingPunctuation: false),
            "you"
        )
    }

    func test_nextAcceptanceChunk_returnsLeftoverPunctuationAsItsOwnPart() {
        // After "you" is accepted, the remaining tail is the bare punctuation, taken whole next.
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptanceChunk(from: "?", autoAcceptTrailingPunctuation: false),
            "?"
        )
    }

    func test_nextAcceptanceChunk_splitsMultipleTrailingMarksAsOnePart() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptanceChunk(from: "you?!", autoAcceptTrailingPunctuation: false),
            "you"
        )
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptanceChunk(from: "?!", autoAcceptTrailingPunctuation: false),
            "?!"
        )
    }

    func test_nextAcceptanceChunk_preservesInternalPunctuationWhenSplitting() {
        // Apostrophes and interior dots are not trailing, so the word stays whole.
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptanceChunk(from: "don't", autoAcceptTrailingPunctuation: false),
            "don't"
        )
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptanceChunk(from: "U.S.A", autoAcceptTrailingPunctuation: false),
            "U.S.A"
        )
    }

    func test_nextAcceptanceChunk_splitsOnlyFinalPeriodAfterInteriorDots() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptanceChunk(from: "U.S.A.", autoAcceptTrailingPunctuation: false),
            "U.S.A"
        )
    }

    func test_nextAcceptanceChunk_keepsLeadingWhitespaceWhenSplittingPunctuation() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptanceChunk(from: " world!", autoAcceptTrailingPunctuation: false),
            " world"
        )
    }

    func test_nextAcceptanceChunk_splittingStopsAtFirstWhitespaceBoundary() {
        // The first token has no trailing punctuation, so splitting leaves it whole and never
        // reaches the punctuation on the following word.
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptanceChunk(from: "hello world?", autoAcceptTrailingPunctuation: false),
            "hello"
        )
    }

    // MARK: - Space-less-script word acceptance

    func test_nextAcceptanceChunk_latinAcceptanceIsUnchangedBySpacelessBranch() {
        // Regression guard: the space-less branch must never alter space-delimited acceptance.
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptanceChunk(from: "hello world"), "hello")
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptanceChunk(from: "don't stop now"), "don't")
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptanceChunk(from: "U.S.A today"), "U.S.A")
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptanceChunk(from: "1.5 times"), "1.5")
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptanceChunk(from: "café René"), "café")
        // A space-less script appearing later in the tail must not pull the first Latin token early.
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptanceChunk(from: "world 你好"), "world")
    }

    func test_nextAcceptanceChunk_segmentsChineseBelowWholeLength() {
        // ICU word segmentation may be per-character or dictionary-based depending on the OS, so this
        // asserts the robust property (accept one segment, not the whole run) rather than a pinned word.
        let run = "你好世界"
        let chunk = SuggestionSessionReconciler.nextAcceptanceChunk(from: run)
        XCTAssertFalse(chunk.isEmpty)
        XCTAssertTrue(run.hasPrefix(chunk))
        XCTAssertLessThan(chunk.count, run.count, "a space-less Chinese run must segment, not accept the whole run")
    }

    func test_nextAcceptanceChunk_segmentsJapaneseRunBelowWholeLength() {
        let run = "今日はいい天気です"
        let chunk = SuggestionSessionReconciler.nextAcceptanceChunk(from: run)
        XCTAssertFalse(chunk.isEmpty)
        XCTAssertTrue(run.hasPrefix(chunk))
        XCTAssertLessThan(chunk.count, run.count, "a space-less Japanese run must segment, not accept whole")
    }

    func test_nextAcceptanceChunk_segmentsThaiRunBelowWholeLength() {
        let run = "สวัสดีครับ"
        let chunk = SuggestionSessionReconciler.nextAcceptanceChunk(from: run)
        XCTAssertFalse(chunk.isEmpty)
        XCTAssertTrue(run.hasPrefix(chunk))
        XCTAssertLessThan(chunk.count, run.count, "a space-less Thai run must segment, not accept whole")
    }

    func test_nextAcceptanceChunk_chineseAcceptanceStaysWithinRunBeforeSpace() {
        let chunk = SuggestionSessionReconciler.nextAcceptanceChunk(from: "你好 world")
        XCTAssertFalse(chunk.isEmpty)
        XCTAssertTrue("你好".hasPrefix(chunk), "acceptance must stay within the CJK run and not cross the space")
        XCTAssertFalse(chunk.contains(" "))
    }

    func test_nextAcceptanceChunk_keepsLeadingWhitespaceBeforeSpacelessWord() {
        let chunk = SuggestionSessionReconciler.nextAcceptanceChunk(from: " 你好世界")
        XCTAssertTrue(chunk.hasPrefix(" "), "leading whitespace is preserved before the segmented word")
        let afterSpace = String(chunk.dropFirst())
        XCTAssertFalse(afterSpace.isEmpty)
        XCTAssertTrue("你好世界".hasPrefix(afterSpace))
        XCTAssertLessThan(afterSpace.count, 4, "only the first segment is accepted, not the whole run")
    }

    // MARK: - Phrase chunker
}
