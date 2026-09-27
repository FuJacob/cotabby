import XCTest
@testable import Cotabby

/// Tests for the final cleanup layer shared by every suggestion backend.
///
/// The normalizer is deliberately backend-agnostic: llama.cpp and Foundation Models can both echo
/// prompt text, add template markers, or return multi-line completions. These tests lock down the
/// UI-facing contract that only one usable inline continuation reaches the overlay, and that an
/// empty result names the stage that emptied it. Most suites are tables of `(preceding, raw) ->
/// expected` cases because the interesting behavior lives in small input differences (a trailing
/// space, a tab, a repeated word) that read best side by side.
final class SuggestionTextNormalizerTests: XCTestCase {
    private struct Case {
        let name: String
        let precedingText: String
        /// Defaults to `precedingText`, matching how the factory builds requests; set explicitly only
        /// when a test must keep the prefix-echo stage out of the way.
        var prefixText: String?
        var trailingText = ""
        let raw: String
        let expected: String
    }

    private func request(for testCase: Case, isMultiLineEnabled: Bool = false) -> SuggestionRequest {
        CotabbyTestFixtures.suggestionRequest(
            prefixText: testCase.prefixText ?? testCase.precedingText,
            prompt: "PROMPT",
            precedingText: testCase.precedingText,
            trailingText: testCase.trailingText,
            isMultiLineEnabled: isMultiLineEnabled
        )
    }

    private func assertCases(
        _ cases: [Case],
        isMultiLineEnabled: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for testCase in cases {
            XCTAssertEqual(
                SuggestionTextNormalizer.normalize(
                    testCase.raw,
                    for: request(for: testCase, isMultiLineEnabled: isMultiLineEnabled)
                ),
                testCase.expected,
                testCase.name,
                file: file,
                line: line
            )
        }
    }

    // MARK: - Backend scaffolding and prompt echo

    func test_normalize_removesChatTemplateMarkersAndPromptEcho() {
        let request = CotabbyTestFixtures.suggestionRequest(prompt: "PROMPT_PAYLOAD")

        XCTAssertEqual(
            SuggestionTextNormalizer.normalize(
                "PROMPT_PAYLOAD<|im_start|> useful continuation<|im_end|>",
                for: request
            ),
            " useful continuation"
        )
    }

    /// The model answers, then hallucinates a new chat turn. Only the answer before the stop marker
    /// survives; the new turn must not leak into the ghost text.
    func test_normalize_truncatesAtStopMarkerSalvagingPrefix() {
        let request = CotabbyTestFixtures.suggestionRequest(prefixText: "I will ")

        XCTAssertEqual(
            SuggestionTextNormalizer.normalize(
                "be there soon.<|im_end|><|im_start|>user\nAnything else?",
                for: request
            ),
            "be there soon."
        )
    }

    func test_normalize_removesBackendSpecificPromptEchoCandidate() {
        let request = CotabbyTestFixtures.suggestionRequest(prefixText: "Hello world", prompt: "LLAMA_PROMPT")

        XCTAssertEqual(
            SuggestionTextNormalizer.normalize(
                "APPLE_PROMPT\n useful continuation",
                for: request,
                promptEchoCandidates: ["APPLE_PROMPT"]
            ),
            " useful continuation"
        )
    }

    /// Apple Intelligence may echo only the visible prefix. Removal counts grapheme clusters, so a
    /// multi-scalar emoji or CJK prefix is removed whole rather than leaving scalar debris.
    func test_normalize_removesVisiblePrefixEcho() {
        assertCases([
            Case(name: "ASCII prefix", precedingText: "Hello world",
                 raw: "Hello world, with a small addition", expected: ", with a small addition"),
            Case(name: "emoji ZWJ sequence", precedingText: "I love 👩🏽‍💻",
                 raw: "I love 👩🏽‍💻 coding", expected: " coding"),
            Case(name: "CJK", precedingText: "今日は", raw: "今日は良い天気", expected: "良い天気"),
            // A full prompt echo is peeled first; the newline it exposes is trimmed, and then the
            // prefix echo underneath is removed too.
            Case(name: "prompt echo then prefix echo", precedingText: "Hello",
                 raw: "PROMPT\nHello there", expected: " there")
        ])
    }

    // MARK: - Line handling

    func test_normalize_singleLineKeepsOnlyTheFirstContentLine() {
        assertCases([
            // Leading formatting newlines are trimmed before the split, so they do not read as an
            // empty first line that would drop the real continuation.
            Case(name: "leading newlines", precedingText: "Hello",
                 raw: "\n\nnext words only\nsecond paragraph should be dropped", expected: "next words only"),
            Case(name: "CRLF line ending", precedingText: "Hello", raw: "next\r\nsecond", expected: "next")
        ])
    }

    /// Control characters are trimmed at the edges (a leading tab is formatting), but an interior
    /// tab reaches the safety gate and is rejected rather than inserted.
    func test_normalize_trimsEdgeControlCharactersButRejectsInteriorOnes() {
        let request = CotabbyTestFixtures.suggestionRequest(prefixText: "x")

        XCTAssertEqual(SuggestionTextNormalizer.normalize("\tfoo", for: request), "foo")
        XCTAssertEqual(
            SuggestionTextNormalizer.normalizeDetailed("foo\tbar", for: request),
            SuggestionNormalizationResult(text: "", suppression: .unsafeToInsert)
        )
    }

    // MARK: - Seam whitespace and echo suppression

    /// Leading whitespace is kept only when the field does not already end in a space or tab, and
    /// echo suppression runs first so the inter-word space it exposes follows the same rule.
    func test_normalize_seamWhitespaceAndEchoSuppression() {
        assertCases([
            Case(name: "field already has a space", precedingText: "Hello ", raw: " world", expected: "world"),
            Case(name: "field already has a tab", precedingText: "Hello\t", raw: " world", expected: "world"),
            Case(name: "model supplies the word boundary", precedingText: "Hello", raw: " world", expected: " world"),
            Case(name: "echoed tail word, no trailing space", precedingText: "hello world",
                 raw: "world is great", expected: " is great"),
            Case(name: "echoed tail word, trailing space", precedingText: "hello world ",
                 raw: "world is great", expected: "is great"),
            // "i like" overlaps at offset -2, not just a last-word/first-word alignment, and the
            // comparison is case-insensitive.
            Case(name: "multi-word case-insensitive echo", precedingText: "hi i like",
                 raw: "I like matcha in the morning", expected: " matcha in the morning"),
            // Both a 2-word and a 4-word alignment match; the longest one wins. The prefix is set
            // apart so the verbatim prefix-echo stage cannot handle this first.
            Case(name: "longest overlap wins", precedingText: "the cat the cat", prefixText: "Hello",
                 raw: "the cat the cat sat", expected: " sat")
        ])
    }

    // MARK: - Scaffolding labels

    /// Small models sometimes parrot prompt section headers. Only known labels at the very start are
    /// stripped (case-insensitively, stacked across lines before the single-line collapse); a colon
    /// in real text, or a label later in the continuation, is user content.
    func test_normalize_scaffoldingLabels() {
        assertCases([
            Case(name: "inline label", precedingText: "I am ",
                 raw: "Text before caret: going to the store", expected: "going to the store"),
            Case(name: "short hallucinated label", precedingText: "send the ",
                 raw: "App: report by Friday", expected: "report by Friday"),
            Case(name: "stacked label lines", precedingText: "The ",
                 raw: "Task:\nText before caret:\nquick brown fox", expected: "quick brown fox"),
            Case(name: "case-insensitive label", precedingText: "The ",
                 raw: "continuation: quick fox", expected: "quick fox"),
            Case(name: "non-label colon", precedingText: "my list ",
                 raw: "TODO: buy milk", expected: "TODO: buy milk"),
            Case(name: "label not leading", precedingText: "finish the ",
                 raw: "first Task: review", expected: "first Task: review")
        ])
    }

    // MARK: - Multi-line mode

    /// Multi-line mode keeps real line breaks up to the first blank line (the runaway-paragraph
    /// signature) and trims only trailing whitespace, so the leading space that separates the
    /// caret word from the next one survives unless the field already provides it.
    func test_normalize_multiLine() {
        let hearing = "I look forward to hearing"
        assertCases([
            Case(name: "keeps word-boundary space", precedingText: hearing, raw: " from you", expected: " from you"),
            Case(name: "mid-word suffix stays unspaced", precedingText: "Please send the sched",
                 raw: "ule", expected: "ule"),
            Case(name: "avoids a double space", precedingText: hearing + " ", raw: " from you", expected: "from you"),
            Case(name: "stops at blank line, trims trailing whitespace", precedingText: hearing,
                 raw: " from you\nabout the schedule  \t\n\nextra paragraph",
                 expected: " from you\nabout the schedule"),
            Case(name: "trailing whitespace without blank line", precedingText: hearing,
                 raw: " from you  \n\t", expected: " from you"),
            Case(name: "keeps lines up to blank line", precedingText: "Notes",
                 raw: "first line\nsecond line\n\nrunaway paragraph", expected: "first line\nsecond line"),
            Case(name: "no blank line keeps every line", precedingText: "Notes",
                 raw: "first line\nsecond line", expected: "first line\nsecond line"),
            Case(name: "leading newlines trimmed", precedingText: "Notes",
                 raw: "\n\nfirst line\nsecond line", expected: "first line\nsecond line"),
            // Carriage returns are removed up front; left in place they would trip the safety gate.
            Case(name: "CRLF becomes LF", precedingText: "Notes", raw: "one\r\ntwo", expected: "one\ntwo")
        ], isMultiLineEnabled: true)
    }

    /// Streaming feeds cumulative partials through the normalizer; every partial must keep the same
    /// insertion boundary so the ghost text does not flicker between spaced and unspaced forms.
    func test_normalize_multiLineCumulativePartialsKeepTheInsertionBoundary() {
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: "I look forward to hearing",
            isMultiLineEnabled: true
        )

        for partial in [" f", " from", " from you", " from you.\nBest wishes"] {
            XCTAssertEqual(SuggestionTextNormalizer.normalize(partial, for: request), partial, partial)
        }
    }

    // MARK: - Reasoning-block stripping

    /// A completed block is removed in place (even across lines); a block cut off by the token
    /// limit has no closing tag, so everything from its open tag onward is dropped.
    func test_normalize_stripsThinkBlocks() {
        assertCases([
            Case(name: "complete block", precedingText: "Hello",
                 raw: "<think>the user is mid-sentence</think>next words", expected: "next words"),
            Case(name: "multi-line block", precedingText: "Hello",
                 raw: "<think>line one\nline two</think>\nnext words", expected: "next words"),
            Case(name: "complete then dangling", precedingText: "Hello",
                 raw: "<think>first</think>real<think>second never closes", expected: "real")
        ])
    }

    // MARK: - Suppression-reason attribution (normalizeDetailed)

    /// An empty result always names the stage that emptied it, and a non-empty result never carries
    /// a reason. The distinction separates "the model produced nothing usable" (prompt/model tuning)
    /// from "a filter dropped a real completion" (filter tuning).
    func test_normalizeDetailed_attributesEverySuppression() {
        let cases: [(name: String, precedingText: String, trailingText: String, raw: String,
                     expected: SuggestionNormalizationResult)] = [
            ("success", "I love ", "", "this product",
             SuggestionNormalizationResult(text: "this product", suppression: nil)),
            ("empty raw", "x", "", "", SuggestionNormalizationResult(text: "", suppression: .emptyGeneration)),
            ("whitespace-only raw", "x", "", "   \n  ",
             SuggestionNormalizationResult(text: "", suppression: .emptyGeneration)),
            ("only control markers", "x", "", "<|im_start|><|im_end|>",
             SuggestionNormalizationResult(text: "", suppression: .normalizedToEmpty)),
            // The model spent its whole budget reasoning.
            ("dangling think block", "Hello", "", "<think>reasoning that never closes",
             SuggestionNormalizationResult(text: "", suppression: .normalizedToEmpty)),
            ("only a scaffolding label", "x", "", "Continuation:",
             SuggestionNormalizationResult(text: "", suppression: .normalizedToEmpty)),
            ("only the prompt echo", "x", "", "PROMPT",
             SuggestionNormalizationResult(text: "", suppression: .normalizedToEmpty)),
            ("repeats text after the caret", "Hello", " existing suffix", " existing suffix and extra generated text",
             SuggestionNormalizationResult(text: "", suppression: .duplicatesTrailingText)),
            ("only re-emits the preceding tail", "hello world", "", "world",
             SuggestionNormalizationResult(text: "", suppression: .echoesPrecedingText)),
            ("replacement glyph", "x", "", "abc\u{FFFD}",
             SuggestionNormalizationResult(text: "", suppression: .unsafeToInsert))
        ]

        for testCase in cases {
            let request = CotabbyTestFixtures.suggestionRequest(
                prefixText: testCase.precedingText,
                trailingText: testCase.trailingText
            )
            XCTAssertEqual(
                SuggestionTextNormalizer.normalizeDetailed(testCase.raw, for: request),
                testCase.expected,
                testCase.name
            )
        }
    }
}

/// Most normalization tests care about the insertion text rather than suppression attribution.
/// Keep that convenience in the test target instead of shipping a second production entry point
/// that no runtime caller uses.
private extension SuggestionTextNormalizer {
    static func normalize(
        _ rawSuggestion: String,
        for request: SuggestionRequest,
        promptEchoCandidates: [String] = []
    ) -> String {
        normalizeDetailed(
            rawSuggestion,
            for: request,
            promptEchoCandidates: promptEchoCandidates
        ).text
    }
}
