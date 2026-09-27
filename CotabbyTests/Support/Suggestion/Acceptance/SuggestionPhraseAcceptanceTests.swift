import XCTest
@testable import Cotabby

/// Phrase-granularity Tab acceptance: where a multi-word accept stops (sentence terminators,
/// newlines, CJK clause commas) and how closers, abbreviations, and CJK punctuation affect that.
final class SuggestionPhraseAcceptanceTests: XCTestCase {
    func test_nextAcceptancePhrase_returnsEmptyForEmptyTail() {
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptancePhrase(from: ""), "")
    }

    func test_nextAcceptancePhrase_returnsWholeTailWhenNoTerminatorPresent() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptancePhrase(from: "hello world again"),
            "hello world again"
        )
    }

    func test_nextAcceptancePhrase_stopsAtFirstASCIISentenceTerminator() {
        let cases: [(tail: String, expected: String)] = [
            ("hello world. foo bar.", "hello world."),
            ("how are you? fine.", "how are you?"),
            ("stop! go back", "stop!")
        ]
        for (tail, expected) in cases {
            XCTAssertEqual(SuggestionSessionReconciler.nextAcceptancePhrase(from: tail), expected, tail)
        }
    }

    /// `nextAcceptanceChunk` returns leading whitespace (including newlines) with the next token, so
    /// a newline would otherwise ride inside the following chunk; the in-chunk newline scan must cut
    /// the phrase right after the first newline wherever it sits.
    func test_nextAcceptancePhrase_stopsJustAfterTheFirstNewline() {
        let cases: [(tail: String, expected: String)] = [
            ("hello\nworld", "hello\n"),
            ("\nworld", "\n"),
            ("\n\nbody", "\n"),
            ("  \n", "  \n"),
            ("hello world\nmore", "hello world\n"),
            // A terminator that closes the line ends the phrase first; the newline then leads the
            // next Tab's phrase instead of being swallowed with this one.
            ("done.\nNext", "done.")
        ]
        for (tail, expected) in cases {
            XCTAssertEqual(SuggestionSessionReconciler.nextAcceptancePhrase(from: tail), expected, tail.debugDescription)
        }
    }

    /// Periods are disambiguated by `SentenceBoundaryClassifier`: list numbers, dotted initials, and
    /// known abbreviations do not end a phrase, so a phrase accept walks on to the real sentence end.
    func test_nextAcceptancePhrase_walksPastNonTerminalPeriods() {
        let cases: [(tail: String, expected: String)] = [
            ("Step 1. Open the app. Then", "Step 1. Open the app."),
            ("e.g. this works. Next", "e.g. this works."),
            ("Ask Dr. Smith today. Then", "Ask Dr. Smith today.")
        ]
        for (tail, expected) in cases {
            XCTAssertEqual(SuggestionSessionReconciler.nextAcceptancePhrase(from: tail), expected, tail)
        }
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
}
