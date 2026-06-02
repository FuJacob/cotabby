import XCTest
@testable import Cotabby

/// Tests for the final cleanup layer shared by every suggestion backend.
///
/// The normalizer is deliberately backend-agnostic: llama.cpp and Foundation Models can both echo
/// prompt text, add template markers, or return multi-line completions. These tests lock down the
/// UI-facing contract that only one usable inline continuation reaches the overlay.
final class SuggestionTextNormalizerTests: XCTestCase {
    func test_normalize_removesChatTemplateMarkersAndPromptEcho() {
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: "Hello",
            prompt: "PROMPT_PAYLOAD",
            precedingText: "Hello"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            "PROMPT_PAYLOAD<|im_start|> useful continuation<|im_end|>",
            for: request
        )

        XCTAssertEqual(normalized, " useful continuation")
    }

    func test_normalize_removesPrefixEchoWhenPromptWasNotEchoed() {
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: "Hello world",
            prompt: "SHORT_APPLE_PROMPT",
            precedingText: "Hello world"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            "Hello world, with a small addition",
            for: request
        )

        XCTAssertEqual(normalized, ", with a small addition")
    }

    func test_normalize_removesBackendSpecificPromptEchoCandidate() {
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: "Hello world",
            prompt: "LLAMA_PROMPT",
            precedingText: "Hello world"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            "APPLE_PROMPT\n useful continuation",
            for: request,
            promptEchoCandidates: ["APPLE_PROMPT"]
        )

        XCTAssertEqual(normalized, " useful continuation")
    }

    func test_normalize_trimsLeadingFormattingNewlinesBeforeTakingFirstLine() {
        let request = CotabbyTestFixtures.suggestionRequest(precedingText: "Hello")

        let normalized = SuggestionTextNormalizer.normalize(
            "\n\nnext words only\nsecond paragraph should be dropped",
            for: request
        )

        XCTAssertEqual(normalized, "next words only")
    }

    func test_normalize_dropsSuggestionThatRepeatsTrailingTextAfterCaret() {
        let request = CotabbyTestFixtures.suggestionRequest(
            precedingText: "Hello",
            trailingText: " existing suffix"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            " existing suffix and extra generated text",
            for: request
        )

        XCTAssertEqual(normalized, "")
    }

    func test_normalize_stripsModelLeadingWhitespaceWhenPrecedingTextAlreadyEndsWithWhitespace() {
        let request = CotabbyTestFixtures.suggestionRequest(precedingText: "Hello ")

        let normalized = SuggestionTextNormalizer.normalize(" world", for: request)

        XCTAssertEqual(normalized, "world")
    }

    func test_normalize_preservesModelLeadingWhitespaceWhenPrecedingTextNeedsWordBoundary() {
        let request = CotabbyTestFixtures.suggestionRequest(precedingText: "Hello")

        let normalized = SuggestionTextNormalizer.normalize(" world", for: request)

        XCTAssertEqual(normalized, " world")
    }

    func test_normalize_stripsRepeatedPrecedingTailAcrossMultipleWords() {
        let request = CotabbyTestFixtures.suggestionRequest(precedingText: "hi i like")

        let normalized = SuggestionTextNormalizer.normalize(
            "I like matcha in the morning",
            for: request
        )

        XCTAssertEqual(normalized, " matcha in the morning")
    }

    func test_normalize_preservesSpaceAfterEchoStrippingWhenPrecedingTextLacksTrailingSpace() {
        let request = CotabbyTestFixtures.suggestionRequest(precedingText: "hello world")

        let normalized = SuggestionTextNormalizer.normalize(
            "world is great",
            for: request
        )

        XCTAssertEqual(normalized, " is great")
    }

    func test_normalize_stripsSpaceAfterEchoStrippingWhenPrecedingTextEndsWithSpace() {
        let request = CotabbyTestFixtures.suggestionRequest(precedingText: "hello world ")

        let normalized = SuggestionTextNormalizer.normalize(
            "world is great",
            for: request
        )

        XCTAssertEqual(normalized, "is great")
    }

    func test_normalize_returnsEmptyWhenSuggestionIsOnlyAnEchoedTailWord() {
        let request = CotabbyTestFixtures.suggestionRequest(precedingText: "hello world")

        let normalized = SuggestionTextNormalizer.normalize("world", for: request)

        XCTAssertEqual(normalized, "")
    }

    func test_normalize_stripsLeadingInlineScaffoldingLabel() {
        // Caret sits right after a space, so the exposed leading space is dropped and the
        // continuation surfaces cleanly without the echoed "Text before caret:" header.
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: "I am ",
            prompt: "PROMPT",
            precedingText: "I am "
        )

        let normalized = SuggestionTextNormalizer.normalize(
            "Text before caret: going to the store",
            for: request
        )

        XCTAssertEqual(normalized, "going to the store")
    }

    func test_normalize_stripsHallucinatedAppLabel() {
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: "send the ",
            prompt: "PROMPT",
            precedingText: "send the "
        )

        let normalized = SuggestionTextNormalizer.normalize(
            "App: report by Friday",
            for: request
        )

        XCTAssertEqual(normalized, "report by Friday")
    }

    func test_normalize_stripsStackedScaffoldingLabelLines() {
        // Stacked labels across newlines must be peeled before the single-line collapse, otherwise
        // the collapse would keep only the first label line ("Task:") and the real text would be
        // lost.
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: "The ",
            prompt: "PROMPT",
            precedingText: "The "
        )

        let normalized = SuggestionTextNormalizer.normalize(
            "Task:\nText before caret:\nquick brown fox",
            for: request
        )

        XCTAssertEqual(normalized, "quick brown fox")
    }

    func test_normalize_keepsLegitimateNonLabelColon() {
        // A colon that is not a known scaffolding label is real user content and must survive.
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: "my list ",
            prompt: "PROMPT",
            precedingText: "my list "
        )

        let normalized = SuggestionTextNormalizer.normalize(
            "TODO: buy milk",
            for: request
        )

        XCTAssertEqual(normalized, "TODO: buy milk")
    }

    func test_normalize_keepsLabelLikeTextWhenNotLeading() {
        // "Task:" appears mid-continuation, not at the start, so it is real text and stays.
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: "finish the ",
            prompt: "PROMPT",
            precedingText: "finish the "
        )

        let normalized = SuggestionTextNormalizer.normalize(
            "first Task: review",
            for: request
        )

        XCTAssertEqual(normalized, "first Task: review")
    }

    // MARK: - Suppression-reason attribution (normalizeDetailed)

    func test_normalizeDetailed_successHasNoSuppressionReason() {
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: "I love ",
            prompt: "PROMPT",
            precedingText: "I love "
        )

        let result = SuggestionTextNormalizer.normalizeDetailed("this product", for: request)

        XCTAssertEqual(result.text, "this product")
        XCTAssertNil(result.suppression)
    }

    func test_normalizeDetailed_reportsDuplicatesTrailingText() {
        let request = CotabbyTestFixtures.suggestionRequest(
            precedingText: "Hello",
            trailingText: " existing suffix"
        )

        let result = SuggestionTextNormalizer.normalizeDetailed(
            " existing suffix and extra generated text",
            for: request
        )

        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.suppression, .duplicatesTrailingText)
    }

    func test_normalizeDetailed_reportsEchoesPrecedingTextWhenFullyEchoed() {
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: "hello world",
            prompt: "PROMPT",
            precedingText: "hello world"
        )

        // The model re-emits the last word of the preceding text and nothing else.
        let result = SuggestionTextNormalizer.normalizeDetailed("world", for: request)

        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.suppression, .echoesPrecedingText)
    }

    func test_normalizeDetailed_reportsUnsafeToInsertForReplacementGlyph() {
        let request = CotabbyTestFixtures.suggestionRequest(precedingText: "x")

        // Real characters survive normalization but carry a U+FFFD replacement glyph.
        let result = SuggestionTextNormalizer.normalizeDetailed("abc\u{FFFD}", for: request)

        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.suppression, .unsafeToInsert)
    }

    func test_normalizeDetailed_reportsEmptyGenerationForWhitespaceOnlyRaw() {
        let request = CotabbyTestFixtures.suggestionRequest(precedingText: "x")

        let result = SuggestionTextNormalizer.normalizeDetailed("   \n  ", for: request)

        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.suppression, .emptyGeneration)
    }

    func test_normalizeDetailed_reportsNormalizedToEmptyWhenOnlyControlMarkers() {
        let request = CotabbyTestFixtures.suggestionRequest(precedingText: "x")

        // Raw had content, but it was entirely chat-template markers that normalization strips.
        let result = SuggestionTextNormalizer.normalizeDetailed("<|im_start|><|im_end|>", for: request)

        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.suppression, .normalizedToEmpty)
    }
}
