import XCTest
@testable import Cotabby

/// Tests `ComposePromptRenderer` — the pure mapping from a `ComposeRequest` to the prompt string
/// fed into the local llama runtime.
///
/// These tests lock down which sections appear in the prompt and how the renderer handles empty
/// or optional fields. The prompt shape is the contract the model relies on, so silent reordering
/// here would degrade Compose Mode quality without any compile-time warning.
final class ComposePromptRendererTests: XCTestCase {
    func test_prompt_includesTaskInstructionsAndFinalDirective() {
        let prompt = ComposePromptRenderer.prompt(for: composeRequest())

        XCTAssertTrue(prompt.contains("This is Compose Mode, not autocomplete and not chat."))
        XCTAssertTrue(prompt.contains("Return only the final typeable draft."))
        // The "Write the full draft now." instruction must remain at the tail so the model is
        // primed to produce the draft directly after the surrounding context block.
        XCTAssertTrue(prompt.hasSuffix("Final instruction:\nWrite the full draft now."))
    }

    func test_prompt_includesApplicationAndTypedPrefix() {
        let prompt = ComposePromptRenderer.prompt(for: composeRequest(
            applicationName: "GitHub",
            typedPrefix: "Thanks for the review — "
        ))

        XCTAssertTrue(prompt.contains("App:\nGitHub"))
        XCTAssertTrue(prompt.contains("Text already typed in the focused field:\nThanks for the review — "))
    }

    func test_prompt_rendersEmptyPlaceholderWhenTypedPrefixIsBlank() {
        let prompt = ComposePromptRenderer.prompt(for: composeRequest(typedPrefix: "   \n  "))

        XCTAssertTrue(prompt.contains("Text already typed in the focused field:\n(empty)"))
    }

    func test_prompt_includesUserNameAndUserTagsWhenProvided() {
        let prompt = ComposePromptRenderer.prompt(for: composeRequest(
            userName: "Jacob",
            userTags: ["engineer", "macOS"]
        ))

        XCTAssertTrue(prompt.contains("User name:\nJacob"))
        XCTAssertTrue(prompt.contains("User profile tags:\nengineer, macOS"))
    }

    func test_prompt_omitsUserNameWhenEmptyAfterTrimming() {
        let prompt = ComposePromptRenderer.prompt(for: composeRequest(userName: "   "))

        XCTAssertFalse(prompt.contains("User name:"))
    }

    func test_prompt_omitsUserTagsWhenEmpty() {
        let prompt = ComposePromptRenderer.prompt(for: composeRequest(userTags: []))

        XCTAssertFalse(prompt.contains("User profile tags:"))
    }

    func test_prompt_includesTrailingTextOnlyWhenNotBlank() {
        let withTrailing = ComposePromptRenderer.prompt(for: composeRequest(trailingText: "...rest of paragraph"))
        XCTAssertTrue(withTrailing.contains("Text after the caret:\n...rest of paragraph"))

        let withoutTrailing = ComposePromptRenderer.prompt(for: composeRequest(trailingText: ""))
        XCTAssertFalse(withoutTrailing.contains("Text after the caret:"))
    }

    func test_prompt_includesClipboardAndVisualContextWhenProvided() {
        let prompt = ComposePromptRenderer.prompt(for: composeRequest(
            visualContextSummary: "PAGE_HEADER",
            clipboardContext: "COPIED_LINK"
        ))

        XCTAssertTrue(prompt.contains("Clipboard context:\nCOPIED_LINK"))
        XCTAssertTrue(prompt.contains("Visual context summary:\nPAGE_HEADER"))
    }

    func test_prompt_includesSurroundingContextEvenWhenEmpty() {
        // The surrounding-context section is always present so the model sees consistent prompt
        // shape across runs; empty content is rendered as "(empty)".
        let prompt = ComposePromptRenderer.prompt(for: composeRequest(surroundingContext: " "))

        XCTAssertTrue(prompt.contains("Relevant surrounding context:\n(empty)"))
    }

    private func composeRequest(
        applicationName: String = "TestApp",
        typedPrefix: String = "Hello",
        trailingText: String = "",
        surroundingContext: String = "Some surrounding context.",
        visualContextSummary: String? = nil,
        clipboardContext: String? = nil,
        userName: String? = nil,
        userTags: [String]? = nil
    ) -> ComposeRequest {
        ComposeRequest(
            context: CotabbyTestFixtures.focusedInputContext(applicationName: applicationName),
            typedPrefix: typedPrefix,
            trailingText: trailingText,
            surroundingContext: surroundingContext,
            visualContextSummary: visualContextSummary,
            clipboardContext: clipboardContext,
            applicationName: applicationName,
            generation: 1,
            maxPredictionTokens: 256,
            temperature: 0.4,
            topK: 40,
            topP: 0.9,
            minP: 0.05,
            repetitionPenalty: 1.1,
            randomSeed: nil,
            userName: userName,
            userTags: userTags
        )
    }
}
