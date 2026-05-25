import XCTest
@testable import Cotabby

/// Tests `ComposeTextNormalizer` — the last-mile cleanup that turns raw llama output into the text
/// Cotabby actually types into the focused field.
///
/// These tests exist because the existing `SuggestionTextNormalizer` aggressively truncates to a
/// short inline tail; Compose has a different contract (preserve paragraphs, strip wrappers).
final class ComposeTextNormalizerTests: XCTestCase {
    func test_normalize_stripsLeadingPromptEcho() {
        let prompt = "PROMPT_SECTION\nFinal instruction:\nWrite the full draft now."
        let raw = prompt + "\nHello team,\n\nThanks for the review."

        let normalized = ComposeTextNormalizer.normalize(raw, prompt: prompt, request: request())

        XCTAssertEqual(normalized, "Hello team,\n\nThanks for the review.")
    }

    func test_normalize_stripsChatTemplateSpecialTokens() {
        let normalized = ComposeTextNormalizer.normalize(
            "<|im_start|>Hello.<|im_end|>",
            prompt: "",
            request: request()
        )

        XCTAssertEqual(normalized, "Hello.")
    }

    func test_normalize_stripsMarkdownFences() {
        let raw = """
        ```
        Hello team,

        Thanks for the review.
        ```
        """

        let normalized = ComposeTextNormalizer.normalize(raw, prompt: "", request: request())

        XCTAssertEqual(normalized, "Hello team,\n\nThanks for the review.")
    }

    func test_normalize_stripsLeadingLabelsCaseInsensitively() {
        let cases: [(String, String)] = [
            ("Final answer: Hello.", "Hello."),
            ("Draft: A short draft.", "A short draft."),
            ("comment: lowercase label", "lowercase label"),
            ("Reply: With a label.", "With a label.")
        ]

        for (raw, expected) in cases {
            let normalized = ComposeTextNormalizer.normalize(raw, prompt: "", request: request())
            XCTAssertEqual(normalized, expected, "expected \(expected) for \(raw)")
        }
    }

    func test_normalize_stripsWrappingQuotesOnly() {
        let doubled = ComposeTextNormalizer.normalize(
            "\"Hello team.\"",
            prompt: "",
            request: request()
        )
        XCTAssertEqual(doubled, "Hello team.")

        // Inline quotes in the middle of a draft must not be stripped — they are content.
        let preserved = ComposeTextNormalizer.normalize(
            "Hello \"team\" again.",
            prompt: "",
            request: request()
        )
        XCTAssertEqual(preserved, "Hello \"team\" again.")
    }

    func test_normalize_stripsTypedPrefixEchoWhenPresent() {
        let typedPrefix = "Thanks for the review — "
        let raw = "Thanks for the review — this looks good to ship."

        let normalized = ComposeTextNormalizer.normalize(
            raw,
            prompt: "",
            request: request(typedPrefix: typedPrefix)
        )

        XCTAssertEqual(normalized, "this looks good to ship.")
    }

    func test_normalize_preservesParagraphBoundariesAndCollapsesRunsOfBlankLines() {
        let raw = """
        Paragraph one.



        Paragraph two.


        Paragraph three.
        """

        let normalized = ComposeTextNormalizer.normalize(raw, prompt: "", request: request())

        XCTAssertEqual(normalized, "Paragraph one.\n\nParagraph two.\n\nParagraph three.")
    }

    func test_normalize_trimsLeadingAndTrailingNewlinesWithoutTouchingContent() {
        let normalized = ComposeTextNormalizer.normalize(
            "\n\n  Paragraph one.\n\nParagraph two.\n\n",
            prompt: "",
            request: request()
        )

        XCTAssertEqual(normalized, "Paragraph one.\n\nParagraph two.")
    }

    func test_normalize_isNoOpWhenPromptEchoIsAbsent() {
        let raw = "Just a clean draft."

        let normalized = ComposeTextNormalizer.normalize(raw, prompt: "DIFFERENT_PROMPT", request: request())

        XCTAssertEqual(normalized, "Just a clean draft.")
    }

    private func request(typedPrefix: String = "") -> ComposeRequest {
        ComposeRequest(
            context: CotabbyTestFixtures.focusedInputContext(),
            typedPrefix: typedPrefix,
            trailingText: "",
            surroundingContext: "",
            visualContextSummary: nil,
            clipboardContext: nil,
            applicationName: "TestApp",
            generation: 1,
            maxPredictionTokens: 256,
            temperature: 0.4,
            topK: 40,
            topP: 0.9,
            minP: 0.05,
            repetitionPenalty: 1.1,
            randomSeed: nil,
            userName: nil,
            userTags: nil
        )
    }
}
