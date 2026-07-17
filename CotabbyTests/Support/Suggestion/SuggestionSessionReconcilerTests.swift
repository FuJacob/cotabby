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

    func test_advanceIfTypedCharactersMatch_returnsNilForEmptyInput() {
        // An empty capture is not a text mutation; advancing by zero would silently re-validate a
        // session that no key event actually confirmed.
        let session = CotabbyTestFixtures.activeSession(fullText: " world again")

        XCTAssertNil(SuggestionSessionReconciler.advanceIfTypedCharactersMatch("", session: session))
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

    // MARK: - CJK phrase boundaries

    /// The reported case: a space-less Japanese sentence must not arrive as one giant Tab. The
    /// ideographic comma is a clause boundary, so phrase accepts advance clause by clause.
    func test_nextAcceptancePhrase_stopsAtIdeographicComma() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: "理解し、その内容を自分の言葉で表現する。"),
            "理解し、"
        )
    }

    func test_nextAcceptancePhrase_stopsAtIdeographicFullStop() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: "その内容を自分の言葉で表現する。次の文"),
            "その内容を自分の言葉で表現する。"
        )
    }

    func test_nextAcceptancePhrase_stopsAtFullwidthExclamationAndQuestion() {
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptancePhrase(from: "すごい！次へ"), "すごい！")
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptancePhrase(from: "いいですか？はい"), "いいですか？")
    }

    /// The closer-walk must work for CJK quotes too: the accumulated tail is `」`, and the
    /// terminator underneath is the ideographic full stop.
    func test_nextAcceptancePhrase_walksPastCJKClosingQuote() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: "終わり。」次の文"),
            "終わり。」"
        )
    }

    /// ASCII commas must stay non-boundaries so English phrase cadence is unchanged by the CJK rules.
    func test_nextAcceptancePhrase_doesNotStopAtAsciiComma() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: "hello, world. next"),
            "hello, world."
        )
    }

    // MARK: - CJK punctuation binding in word chunks

    /// Trailing CJK punctuation binds to the word it follows, so one Tab accepts the word and its
    /// comma as a unit instead of stranding the comma to lead the next chunk.
    func test_nextAcceptanceChunk_bindsTrailingIdeographicCommaToWord() {
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptanceChunk(from: "資料、内容"), "資料、")
    }

    /// A punctuation-led tail peels the punctuation run as its own chunk. Before this rule the token
    /// skipped ICU segmentation (punctuation does not begin a space-less-script word) and the accept
    /// swallowed everything up to the next whitespace in one chunk.
    func test_nextAcceptanceChunk_peelsLeadingCJKPunctuationRunInsteadOfSwallowingTheTail() {
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptanceChunk(from: "、理解し、その内容"), "、")
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptanceChunk(from: "。」次の文"), "。」")
    }

    /// CJK opening brackets are peeled too: `「` leads the word it quotes, so it neither begins a
    /// space-less-script word nor binds to the preceding one, and without the peel a quoted run in
    /// flat text would be swallowed whole (`「分かった」と言った` after `は` in one Tab).
    func test_nextAcceptanceChunk_peelsLeadingCJKOpeningBracket() {
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptanceChunk(from: "「分かった」と言った"), "「")
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptanceChunk(from: "【内容】次"), "【")
    }

    /// A mixed close-then-open run (`。」「`) peels as one punctuation chunk, so back-to-back quotes
    /// never strand the walker.
    func test_nextAcceptanceChunk_peelsMixedCloserOpenerRunAsOneChunk() {
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptanceChunk(from: "。」「次の文"), "。」「")
    }

    /// The katakana middle dot lives in the kana block, so it enters the ICU branch, but a run of
    /// middle dots contains no segmentable word. The chunker must fall back to the whole
    /// whitespace-bounded token rather than producing an empty chunk and stalling.
    func test_nextAcceptanceChunk_kanaPunctuationRunWithoutWordsAcceptsWholeToken() {
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptanceChunk(from: "・・・ あと"), "・・・")
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptanceChunk(from: "・・・"), "・・・")
    }

    /// The trailing binding must stop before an opening bracket: the closer and full stop belong to
    /// the word, but the next quote's opener belongs to the next word.
    func test_nextAcceptanceChunk_trailingBindingStopsBeforeOpeningBracket() {
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptanceChunk(from: "内容。「次"), "内容。")
    }

    /// Halfwidth kana punctuation (legacy SJIS contexts) behaves like its fullwidth counterparts:
    /// the halfwidth comma is a clause boundary and the halfwidth corner bracket binds and walks.
    func test_halfwidthKanaPunctuation_matchesFullwidthBehavior() {
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptancePhrase(from: "資料を読み､次へ"), "資料を読み､")
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptancePhrase(from: "終わり｡｣次の文"), "終わり｡｣")
    }

    /// ASCII brackets and quotes must keep their existing whole-token behavior: the CJK opener peel
    /// is scoped to CJK codepoints, so space-delimited scripts stay byte-for-byte unchanged.
    func test_nextAcceptanceChunk_asciiBracketsUnchangedByOpenerPeel() {
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptanceChunk(from: "(hello) world"), "(hello)")
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptanceChunk(from: "\"quote\" next"), "\"quote\"")
    }

    // MARK: - CJK punctuation under trailing-punctuation policy

    /// With trailing-punctuation auto-accept off, the CJK binding is intentionally re-peeled: the word
    /// accepts on its own and the clause comma waits for the next Tab, exactly how ASCII trailing
    /// punctuation behaves under the same setting. The binding is a no-op in this path by design.
    func test_nextAcceptanceChunk_autoAcceptOff_trimsBoundCJKCommaBackOffTheWord() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptanceChunk(from: "資料、内容", autoAcceptTrailingPunctuation: false),
            "資料"
        )
    }

    /// A punctuation-led peel must stay non-empty with auto-accept off. Trimming would otherwise strip
    /// the whole chunk and stall the phrase walker, but `wordEndTrimmingTrailingPunctuation` returns
    /// nil for a punctuation-only token, so the comma survives as its own chunk.
    func test_nextAcceptanceChunk_autoAcceptOff_keepsPunctuationOnlyPeelNonEmpty() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptanceChunk(from: "、内容", autoAcceptTrailingPunctuation: false),
            "、"
        )
    }

    /// The flag never changes phrase output: with auto-accept off the word and comma arrive as separate
    /// chunks, but they accumulate to the same clause the flag-on path returns in one binding.
    func test_nextAcceptancePhrase_autoAcceptOff_stillStopsAtIdeographicComma() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(
                from: "理解し、その内容を自分の言葉で表現する。",
                autoAcceptTrailingPunctuation: false
            ),
            "理解し、"
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

    func test_nextAcceptancePhrase_chunkOfOnlyClosingPunctuationIsNotABoundary() {
        // The closer walk-back can consume the entire accumulated chunk; with no character left
        // underneath there is no terminator, so the phrase must keep accumulating.
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: "\"\" hello"),
            "\"\" hello"
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

    func test_overlayHideReason_acceptanceAndOtherEventsUseTheGenericReason() {
        // Acceptance-driven hides are expected behavior, not invalidation, so they get the plain
        // message; shortcut mutations read as typing.
        for kind in [CapturedInputEvent.Kind.acceptance, .fullAcceptance, .other] {
            XCTAssertEqual(
                SuggestionSessionReconciler.overlayHideReason(
                    for: CotabbyTestFixtures.inputEvent(kind: kind)
                ),
                "Overlay hidden."
            )
        }
        XCTAssertEqual(
            SuggestionSessionReconciler.overlayHideReason(
                for: CotabbyTestFixtures.inputEvent(kind: .shortcutMutation)
            ),
            "Overlay hidden because typing invalidated the current suggestion."
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

    func test_reconcile_invalidWhenSuggestionPartiallyUndoneOutsideInsertionSyncWindow() {
        // The session has consumed " worl" (5 chars) but the live field only shows " wo": the user
        // deleted part of the accepted text, so the session must die.
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again",
            consumedCharacterCount: 5,
            basePrecedingText: "Hello"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello wo")

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: nil
        )

        assertInvalid(
            reconciliation,
            reason: "Overlay hidden because the active suggestion was partially undone."
        )
    }

    func test_reconcile_toleratesShorterConsumedSuffixRightAfterAcceptedInsertion() {
        // Same field state as the undo case, but we just Tab-inserted up to 5 consumed characters
        // (the sentinel matches): AX simply has not published the full insert yet, so the session
        // must survive untouched for one more cycle.
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again",
            consumedCharacterCount: 5,
            basePrecedingText: "Hello"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello wo")

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: 5
        )

        guard case let .valid(reconciledSession, advancement, nextPending) = reconciliation else {
            XCTFail("Expected post-insertion AX lag to be tolerated")
            return
        }
        XCTAssertEqual(reconciledSession.acceptedText, session.acceptedText)
        XCTAssertEqual(reconciledSession.remainingText, session.remainingText)
        XCTAssertNil(advancement)
        XCTAssertEqual(nextPending, 5)
    }

    func test_reconcile_toleratesPrefixAnchorRaceRightAfterAcceptedInsertion() {
        // Inverse Chromium race: trailing text already stable, but the prefix still reflects the
        // pre-insertion snapshot. With the sentinel armed the session waits instead of dying.
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again",
            consumedCharacterCount: 6,
            basePrecedingText: "Hello"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(precedingText: "Goodbye")

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: 6
        )

        guard case let .valid(reconciledSession, advancement, nextPending) = reconciliation else {
            XCTFail("Expected prefix-anchor race to be tolerated during the insertion sync window")
            return
        }
        XCTAssertEqual(reconciledSession.remainingText, session.remainingText)
        XCTAssertNil(advancement)
        XCTAssertEqual(nextPending, 6)
    }

    func test_reconcile_toleratesConsumedSuffixDivergenceRightAfterAcceptedInsertion() {
        // The preceding text grew with characters that do not match the suggestion: outside the
        // sync window that is invalidating, but right after Tab it is just stale AX content.
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again",
            consumedCharacterCount: 6,
            basePrecedingText: "Hello"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(precedingText: "Helloxyz")

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: 6
        )

        guard case let .valid(reconciledSession, advancement, nextPending) = reconciliation else {
            XCTFail("Expected consumed-suffix divergence to be tolerated during the insertion sync window")
            return
        }
        XCTAssertEqual(reconciledSession.remainingText, session.remainingText)
        XCTAssertNil(advancement)
        XCTAssertEqual(nextPending, 6)
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
