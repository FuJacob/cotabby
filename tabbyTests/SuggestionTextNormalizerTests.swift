import XCTest
@testable import tabby

/// Tests for the final cleanup layer shared by every suggestion backend.
///
/// The normalizer is deliberately backend-agnostic: llama.cpp and Foundation Models can both echo
/// prompt text, add template markers, or return multi-line completions. These tests lock down the
/// UI-facing contract that only one usable inline continuation reaches the overlay.
final class SuggestionTextNormalizerTests: XCTestCase {
    func test_normalize_removesChatTemplateMarkersAndPromptEcho() {
        let request = TabbyTestFixtures.suggestionRequest(
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
        let request = TabbyTestFixtures.suggestionRequest(
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

    func test_normalize_trimsLeadingFormattingNewlinesBeforeTakingFirstLine() {
        let request = TabbyTestFixtures.suggestionRequest(precedingText: "Hello")

        let normalized = SuggestionTextNormalizer.normalize(
            "\n\nnext words only\nsecond paragraph should be dropped",
            for: request
        )

        XCTAssertEqual(normalized, "next words only")
    }

    func test_normalize_dropsSuggestionThatRepeatsTrailingTextAfterCaret() {
        let request = TabbyTestFixtures.suggestionRequest(
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
        let request = TabbyTestFixtures.suggestionRequest(precedingText: "Hello ")

        let normalized = SuggestionTextNormalizer.normalize(" world", for: request)

        XCTAssertEqual(normalized, "world")
    }

    func test_normalize_preservesModelLeadingWhitespaceWhenPrecedingTextNeedsWordBoundary() {
        let request = TabbyTestFixtures.suggestionRequest(precedingText: "Hello")

        let normalized = SuggestionTextNormalizer.normalize(" world", for: request)

        XCTAssertEqual(normalized, " world")
    }

    func test_normalize_stripsRepeatedPrecedingTailAcrossMultipleWords() {
        let request = TabbyTestFixtures.suggestionRequest(precedingText: "hi i like")

        let normalized = SuggestionTextNormalizer.normalize(
            "I like matcha in the morning",
            for: request
        )

        XCTAssertEqual(normalized, "matcha in the morning")
    }

    func test_normalize_returnsEmptyWhenSuggestionIsOnlyAnEchoedTailWord() {
        let request = TabbyTestFixtures.suggestionRequest(precedingText: "hello world")

        let normalized = SuggestionTextNormalizer.normalize("world", for: request)

        XCTAssertEqual(normalized, "")
    }
}
