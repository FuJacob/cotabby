import XCTest
@testable import Cotabby

/// Focused coverage for one responsibility of `SuggestionSessionReconciler`.
final class SuggestionInsertionChunkTests: XCTestCase {
    func test_insertionChunk_dropsLeadingSpaceWhenPrecedingTextAlreadyEndsInWhitespace() {
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: " you", precedingText: "How are "),
            "you"
        )
    }

    func test_insertionChunk_keepsLeadingSpaceWhenPrecedingTextHasNoTrailingWhitespace() {
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: " you", precedingText: "How are"),
            " you"
        )
    }

    func test_insertionChunk_collapsesAWholeLeadingRunAgainstFieldWhitespace() {
        // The reported "bunch of spaces" case: a field that already ends in a space plus a chunk
        // carrying its own leading space(s) must not stack them.
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: "  you", precedingText: "How are "),
            "you"
        )
    }

    func test_insertionChunk_leavesChunkUntouchedWhenItHasNoLeadingWhitespace() {
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: "you", precedingText: "How are "),
            "you"
        )
    }

    func test_insertionChunk_treatsTabAsBoundaryWhitespaceButNotNewline() {
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: " you", precedingText: "How are\t"),
            "you"
        )
        // Newlines are not horizontal whitespace, so a leading space after a line break is kept.
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: " you", precedingText: "line\n"),
            " you"
        )
    }

    func test_insertionChunk_preservesInterWordSpaceMidSuggestion() {
        // After "you" was already inserted, the field ends in a word, so the next chunk's space
        // is the real boundary and must survive.
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: " are", precedingText: "How are you"),
            " are"
        )
    }

    func test_insertionChunk_returnsChunkUnchangedForEmptyPrecedingText() {
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: " you", precedingText: ""),
            " you"
        )
    }

    func test_insertionChunk_continuesPartialWordWhenModelOmitsLeadingSpace() {
        // Regression for issue #621 ("after" -> "afternoon" committing as "after noon"): the caret
        // sits at the end of a partial word and the model continues it with no leading space. We type
        // the continuation verbatim so it glues into one word instead of synthesizing a boundary.
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: "noon", precedingText: "after"),
            "noon"
        )
    }

    func test_insertionChunk_trustsModelAndDoesNotSynthesizeBoundary() {
        // Trust-the-model: when the chunk has no leading space and the field ends in a word
        // character, we no longer insert one. A genuine new word arrives with the model's own leading
        // space (see `keepsLeadingSpaceWhenPrecedingTextHasNoTrailingWhitespace`); when the model
        // omits it the words glue, which is exactly what the ghost text showed, so accept stays
        // WYSIWYG.
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: "World", precedingText: "Hello"),
            "World"
        )
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: "world", precedingText: "the"),
            "world"
        )
    }

    func test_insertionChunk_doesNotSynthesizeBoundaryAcrossDigitWordBoundary() {
        // Same trust-the-model contract across a digit/letter boundary: no synthesized separator, so
        // the model decides whether "123" continues into "abc" or stands apart.
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: "abc", precedingText: "123"),
            "abc"
        )
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: "1st", precedingText: "Hello"),
            "1st"
        )
    }

    func test_insertionChunk_doesNotAddBoundarySpaceWhenChunkStartsWithPunctuation() {
        // Punctuation-leading chunks ("." closes a sentence, "'s" is a possessive, "," is a list
        // continuation) intentionally attach to the prior word without a separator.
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: ".", precedingText: "Hello"),
            "."
        )
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: "'s", precedingText: "John"),
            "'s"
        )
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: ", more", precedingText: "first"),
            ", more"
        )
    }

    func test_insertionChunk_doesNotAddBoundarySpaceAfterPunctuation() {
        // Opening punctuation in the prefix means the chunk should hug it, not be separated from it.
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: "World", precedingText: "Hello ("),
            "World"
        )
    }

    func test_insertionChunk_doesNotAddBoundarySpaceAfterNewline() {
        // A line break is a hard boundary on its own; we should not synthesize an indent space here.
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: "World", precedingText: "line\n"),
            "World"
        )
    }

    func test_insertionChunk_doesNotAddBoundarySpaceWhenPrecedingTextIsEmpty() {
        // At the very start of an empty field there is no last word to glue onto.
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: "World", precedingText: ""),
            "World"
        )
    }

    func test_insertionChunk_dropsLeadingHorizontalWhitespaceButNotLeadingNewline() {
        // The drop predicate must mirror the guard's horizontal-whitespace definition, so a chunk
        // whose first character is a newline survives even when the field ends in a space — keeping
        // the structural line break the suggestion was authored with.
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: "\nnext", precedingText: "first "),
            "\nnext"
        )
    }

    func test_insertionChunkAppendingTrailingSpace_appendsAfterFinishedWord() {
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunkAppendingTrailingSpace("hello"),
            "hello "
        )
    }

    func test_insertionChunkAppendingTrailingSpace_appendsAfterTrailingDigit() {
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunkAppendingTrailingSpace("section 12"),
            "section 12 "
        )
    }

    func test_insertionChunkAppendingTrailingSpace_skipsWhenEndingInPunctuation() {
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunkAppendingTrailingSpace("done."),
            "done."
        )
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunkAppendingTrailingSpace("really?!"),
            "really?!"
        )
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunkAppendingTrailingSpace("(yes)"),
            "(yes)"
        )
    }

    func test_insertionChunkAppendingTrailingSpace_skipsWhenAlreadyEndingInWhitespace() {
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunkAppendingTrailingSpace("hello "),
            "hello "
        )
    }

    func test_insertionChunkAppendingTrailingSpace_skipsForSpacelessScript() {
        // CJK glyphs are letters, but their scripts never separate words with spaces, so a trailing
        // space would be wrong. The space-less-script guard suppresses it.
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunkAppendingTrailingSpace("資料"),
            "資料"
        )
    }

    func test_insertionChunkAppendingTrailingSpace_leavesEmptyChunkUntouched() {
        XCTAssertEqual(
            SuggestionSessionReconciler.insertionChunkAppendingTrailingSpace(""),
            ""
        )
    }

    func test_acceptanceChunkConsumingTrailingSpace_takesFollowingSpaceAfterWord() {
        XCTAssertEqual(
            SuggestionSessionReconciler.acceptanceChunkConsumingTrailingSpace("world", remainingText: "world how are you"),
            "world "
        )
    }

    func test_acceptanceChunkConsumingTrailingSpace_keepsLeadingWhitespaceAndTakesFollowingSpace() {
        // nextAcceptanceChunk returns leading whitespace with the token, so the extension must keep it
        // and still consume the space that follows the word.
        XCTAssertEqual(
            SuggestionSessionReconciler.acceptanceChunkConsumingTrailingSpace(" world", remainingText: " world how"),
            " world "
        )
    }

    func test_acceptanceChunkConsumingTrailingSpace_takesWholeHorizontalRun() {
        XCTAssertEqual(
            SuggestionSessionReconciler.acceptanceChunkConsumingTrailingSpace("world", remainingText: "world\t  how"),
            "world\t  "
        )
    }

    func test_acceptanceChunkConsumingTrailingSpace_noFollowingWhitespaceLeavesChunkUntouched() {
        // End of the suggestion: nothing to consume here — the exhaustion-time append covers it.
        XCTAssertEqual(
            SuggestionSessionReconciler.acceptanceChunkConsumingTrailingSpace("world", remainingText: "world"),
            "world"
        )
    }

    func test_acceptanceChunkConsumingTrailingSpace_doesNotCrossNewline() {
        XCTAssertEqual(
            SuggestionSessionReconciler.acceptanceChunkConsumingTrailingSpace("line", remainingText: "line\nnext"),
            "line"
        )
    }

    func test_acceptanceChunkConsumingTrailingSpace_doesNotConsumeBeforePunctuation() {
        XCTAssertEqual(
            SuggestionSessionReconciler.acceptanceChunkConsumingTrailingSpace("world", remainingText: "world, how"),
            "world"
        )
    }

    func test_acceptanceChunkConsumingTrailingSpace_skipsWhenChunkEndsInPunctuation() {
        XCTAssertEqual(
            SuggestionSessionReconciler.acceptanceChunkConsumingTrailingSpace("done.", remainingText: "done. next"),
            "done."
        )
    }

    func test_acceptanceChunkConsumingTrailingSpace_skipsForSpacelessScript() {
        // CJK scripts do not separate words with spaces, so even a stray following space is not taken.
        XCTAssertEqual(
            SuggestionSessionReconciler.acceptanceChunkConsumingTrailingSpace("資料", remainingText: "資料 です"),
            "資料"
        )
    }

    func test_acceptedWordCount_countsOnlyTokensWithAlphanumerics() {
        let count = SuggestionSessionReconciler.acceptedWordCount(
            in: "hello, !!! world 123 --"
        )

        XCTAssertEqual(count, 3)
    }
}
