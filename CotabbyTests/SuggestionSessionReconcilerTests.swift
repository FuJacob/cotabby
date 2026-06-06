import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the pure state-machine rules behind partial acceptance.
///
/// This is the highest-risk autocomplete logic because it decides whether a live editor change is
/// still consistent with the active ghost-text tail or whether Cotabby must invalidate the session.
final class SuggestionSessionReconcilerTests: XCTestCase {
    func test_advanceIfTypedCharactersMatch_advancesMatchingDirectText() {
        let session = CotabbyTestFixtures.activeSession(fullText: " world again")

        let advanced = SuggestionSessionReconciler.advanceIfTypedCharactersMatch(
            " world",
            session: session
        )

        XCTAssertEqual(advanced?.acceptedText, " world")
        XCTAssertEqual(advanced?.remainingText, " again")
    }

    func test_advanceIfTypedCharactersMatch_returnsNilForDivergentText() {
        let session = CotabbyTestFixtures.activeSession(fullText: " world again")

        let advanced = SuggestionSessionReconciler.advanceIfTypedCharactersMatch(
            " there",
            session: session
        )

        XCTAssertNil(advanced)
    }

    func test_advanceIfTypedCharactersMatch_returnsNilForControlCharacters() {
        let session = CotabbyTestFixtures.activeSession(fullText: " world again")

        let advanced = SuggestionSessionReconciler.advanceIfTypedCharactersMatch(
            "\n",
            session: session
        )

        XCTAssertNil(advanced)
    }

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

    func test_nextAcceptancePhrase_returnsEmptyForEmptyTail() {
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptancePhrase(from: ""), "")
    }

    func test_nextAcceptancePhrase_returnsWholeTailWhenNoTerminatorPresent() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: "hello world again"),
            "hello world again"
        )
    }

    func test_nextAcceptancePhrase_stopsAtFirstPeriod() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: "hello world. foo bar."),
            "hello world."
        )
    }

    func test_nextAcceptancePhrase_stopsAtFirstQuestionMark() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: "how are you? fine."),
            "how are you?"
        )
    }

    func test_nextAcceptancePhrase_stopsAtFirstExclamation() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: "stop! go back"),
            "stop!"
        )
    }

    func test_nextAcceptancePhrase_stopsAtNewlineBetweenTokens() {
        // Composition over the word chunker would otherwise carry the newline as leading whitespace
        // into the next iteration's accumulated chunk; the in-chunk newline scan must catch it.
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: "hello\nworld"),
            "hello\n"
        )
    }

    func test_nextAcceptancePhrase_stopsAtLeadingNewline() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: "\nworld"),
            "\n"
        )
    }

    func test_nextAcceptancePhrase_stopsAtFirstOfMultipleNewlines() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: "\n\nbody"),
            "\n"
        )
    }

    func test_nextAcceptancePhrase_includesLeadingWhitespaceUpToTerminator() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: "  hello. world."),
            "  hello."
        )
    }

    func test_nextAcceptancePhrase_preservesInteriorPunctuationWithinTokens() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: "don't go. yes"),
            "don't go."
        )
    }

    func test_nextAcceptancePhrase_walksPastDottedInitialsToRealSentenceEnd() {
        // "U.S.A." is a run of single-letter initials, so its interior periods are not sentence
        // ends. SentenceBoundaryClassifier keeps phrase acceptance going until the real terminator
        // after "great" (see SentenceBoundaryClassifierTests for the period-disambiguation rules).
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: "U.S.A. is great."),
            "U.S.A. is great."
        )
    }

    func test_nextAcceptancePhrase_isInvariantToAutoAcceptTrailingPunctuationFlag() {
        let tail = "you? Yes."
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: tail, autoAcceptTrailingPunctuation: true),
            "you?"
        )
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: tail, autoAcceptTrailingPunctuation: false),
            "you?"
        )
    }

    func test_nextAcceptancePhrase_stopsAtNewlineEvenWhenPunctuationPrecedes() {
        // The newline must win over a sentence-terminator on the same line so paragraph breaks are
        // never accidentally skipped past.
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: "hello world\nmore"),
            "hello world\n"
        )
    }

    func test_nextAcceptancePhrase_stopsAtSentenceEndInsideStraightQuotes() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: "\"done.\" Next sentence."),
            "\"done.\""
        )
    }

    func test_nextAcceptancePhrase_stopsAtSentenceEndInsideCurlyQuotes() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: "\u{201C}done.\u{201D} Next."),
            "\u{201C}done.\u{201D}"
        )
    }

    func test_nextAcceptancePhrase_stopsAtSentenceEndInsideParentheses() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: "(yes!) keep going"),
            "(yes!)"
        )
    }

    func test_nextAcceptancePhrase_walksPastMultipleClosingPunctuation() {
        // Nested closers — quote inside parens, sentence ends inside both.
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: "(\"done.\") next"),
            "(\"done.\")"
        )
    }

    func test_nextAcceptancePhrase_doesNotBreakOnBareClosingQuote() {
        // Closing quote with no preceding sentence terminator is not a phrase boundary.
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: "\"hi\" there"),
            "\"hi\" there"
        )
    }

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

    func test_acceptedWordCount_countsOnlyTokensWithAlphanumerics() {
        let count = SuggestionSessionReconciler.acceptedWordCount(
            in: "hello, !!! world 123 --"
        )

        XCTAssertEqual(count, 3)
    }

    func test_overlayAllowsAcceptance_trueWhenOverlayHidden() {
        XCTAssertTrue(
            SuggestionSessionReconciler.overlayAllowsAcceptance(
                of: " world",
                overlayState: .hidden(reason: "waiting for AX")
            )
        )
    }

    func test_overlayAllowsAcceptance_trueOnlyWhenVisibleTextMatches() {
        let caretRect = CGRect(x: 10, y: 20, width: 2, height: 18)

        XCTAssertTrue(
            SuggestionSessionReconciler.overlayAllowsAcceptance(
                of: " world",
                overlayState: .visible(
                    text: " world",
                    geometry: CotabbyTestFixtures.overlayGeometry(caretRect: caretRect),
                    mode: .inline
                )
            )
        )
        XCTAssertFalse(
            SuggestionSessionReconciler.overlayAllowsAcceptance(
                of: " world",
                overlayState: .visible(
                    text: " there",
                    geometry: CotabbyTestFixtures.overlayGeometry(caretRect: caretRect),
                    mode: .inline
                )
            )
        )
    }

    func test_overlayHideReason_mapsSemanticInputEventsToUserVisibleReasons() {
        XCTAssertEqual(
            SuggestionSessionReconciler.overlayHideReason(
                for: CotabbyTestFixtures.inputEvent(kind: .textMutation)
            ),
            "Overlay hidden because typing invalidated the current suggestion."
        )
        XCTAssertEqual(
            SuggestionSessionReconciler.overlayHideReason(
                for: CotabbyTestFixtures.inputEvent(kind: .navigation)
            ),
            "Overlay hidden because caret navigation invalidated the current suggestion."
        )
        XCTAssertEqual(
            SuggestionSessionReconciler.overlayHideReason(
                for: CotabbyTestFixtures.inputEvent(kind: .dismissal)
            ),
            "Overlay hidden because a dismissal key was pressed."
        )
    }

    func test_reconcile_validWhenLiveContextStillMatchesBaseContext() {
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again",
            basePrecedingText: "Hello",
            baseTrailingText: " tail"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(
            precedingText: "Hello",
            trailingText: " tail"
        )

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: nil
        )

        guard case let .valid(reconciledSession, advancement, nextPending) = reconciliation else {
            XCTFail("Expected valid reconciliation")
            return
        }
        XCTAssertEqual(reconciledSession.acceptedText, session.acceptedText)
        XCTAssertEqual(reconciledSession.remainingText, session.remainingText)
        XCTAssertNil(advancement)
        XCTAssertNil(nextPending)
    }

    func test_reconcile_invalidWhenProcessChanges() {
        let session = CotabbyTestFixtures.activeSession(processIdentifier: 123)
        let liveContext = CotabbyTestFixtures.focusedInputContext(processIdentifier: 456)

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: nil
        )

        assertInvalid(
            reconciliation,
            reason: "Overlay hidden because the focused field changed."
        )
    }

    func test_reconcile_invalidWhenTextIsSelected() {
        let session = CotabbyTestFixtures.activeSession()
        let liveContext = CotabbyTestFixtures.focusedInputContext(
            selection: NSRange(location: 1, length: 2)
        )

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: nil
        )

        assertInvalid(reconciliation, reason: "Overlay hidden because text is selected.")
    }

    func test_reconcile_invalidWhenTrailingTextChangesOutsideInsertionSyncWindow() {
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again",
            basePrecedingText: "Hello",
            baseTrailingText: " tail"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(
            precedingText: "Hello",
            trailingText: " changed"
        )

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: nil
        )

        assertInvalid(
            reconciliation,
            reason: "Overlay hidden because text after the caret changed."
        )
    }

    func test_reconcile_toleratesTrailingTextRaceAfterAcceptedInsertion() {
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again",
            consumedCharacterCount: 6,
            basePrecedingText: "Hello",
            baseTrailingText: " tail"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(
            precedingText: "Hello",
            trailingText: " changed"
        )

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: 6
        )

        guard case let .valid(reconciledSession, advancement, nextPending) = reconciliation else {
            XCTFail("Expected transient insertion lag to be tolerated")
            return
        }
        XCTAssertEqual(reconciledSession.acceptedText, session.acceptedText)
        XCTAssertEqual(reconciledSession.remainingText, session.remainingText)
        XCTAssertNil(advancement)
        XCTAssertEqual(nextPending, 6)
    }

    func test_reconcile_invalidWhenPrefixAnchorChangesOutsideInsertionSyncWindow() {
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again",
            basePrecedingText: "Hello"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(precedingText: "Goodbye")

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: nil
        )

        assertInvalid(
            reconciliation,
            reason: "Overlay hidden because text before the caret no longer matches the suggestion anchor."
        )
    }

    func test_reconcile_invalidWhenConsumedSuffixDivergesFromSuggestion() {
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again",
            basePrecedingText: "Hello"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello there")

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: nil
        )

        assertInvalid(
            reconciliation,
            reason: "Overlay hidden because typed text diverged from the active suggestion."
        )
    }

    func test_reconcile_advancesSessionWhenLiveTextConsumedSuggestionPrefix() {
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again",
            basePrecedingText: "Hello"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello world")

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: nil
        )

        guard case let .valid(reconciledSession, advancement, nextPending) = reconciliation else {
            XCTFail("Expected consumed suggestion text to advance the session")
            return
        }
        XCTAssertEqual(reconciledSession.acceptedText, " world")
        XCTAssertEqual(reconciledSession.remainingText, " again")
        XCTAssertEqual(advancement?.stage, "session-reconciled")
        XCTAssertNil(nextPending)
    }

    func test_reconcile_clearsPendingInsertionSentinelWhenAXCatchesUp() {
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again",
            consumedCharacterCount: 6,
            basePrecedingText: "Hello"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello world")

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: 6
        )

        guard case let .valid(_, _, nextPending) = reconciliation else {
            XCTFail("Expected caught-up AX state to remain valid")
            return
        }
        XCTAssertNil(nextPending)
    }

    func test_isStaleAcceptanceEcho_dropsRepeatOfAcceptedTailWhileFieldUnchanged() {
        XCTAssertTrue(
            SuggestionSessionReconciler.isStaleAcceptanceEcho(
                resultText: " today",
                acceptedChunk: " today",
                currentPrecedingText: "what's on your mind",
                acceptedPrecedingText: "what's on your mind"
            )
        )
    }

    func test_isStaleAcceptanceEcho_toleratesLeadingWhitespaceDifference() {
        XCTAssertTrue(
            SuggestionSessionReconciler.isStaleAcceptanceEcho(
                resultText: "today",
                acceptedChunk: " today",
                currentPrecedingText: "what's on your mind",
                acceptedPrecedingText: "what's on your mind"
            )
        )
    }

    func test_isStaleAcceptanceEcho_allowsSuggestionOnceTheInsertPublished() {
        XCTAssertFalse(
            SuggestionSessionReconciler.isStaleAcceptanceEcho(
                resultText: " today",
                acceptedChunk: " today",
                currentPrecedingText: "what's on your mind today",
                acceptedPrecedingText: "what's on your mind"
            )
        )
    }

    func test_isStaleAcceptanceEcho_allowsGenuinelyDifferentContinuation() {
        XCTAssertFalse(
            SuggestionSessionReconciler.isStaleAcceptanceEcho(
                resultText: " tomorrow",
                acceptedChunk: " today",
                currentPrecedingText: "what's on your mind",
                acceptedPrecedingText: "what's on your mind"
            )
        )
    }

    func test_isStaleAcceptanceEcho_ignoresWhitespaceOnlyAcceptedChunk() {
        XCTAssertFalse(
            SuggestionSessionReconciler.isStaleAcceptanceEcho(
                resultText: " ",
                acceptedChunk: " ",
                currentPrecedingText: "what's on your mind",
                acceptedPrecedingText: "what's on your mind"
            )
        )
    }

    private func assertInvalid(
        _ reconciliation: SuggestionSessionReconciliation,
        reason expectedReason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .invalid(reason) = reconciliation else {
            XCTFail("Expected invalid reconciliation", file: file, line: line)
            return
        }

        XCTAssertEqual(reason, expectedReason, file: file, line: line)
    }
}
