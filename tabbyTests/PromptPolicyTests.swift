import XCTest
@testable import tabby

/// Tests for prompt-policy helpers shared by llama.cpp and Foundation Models.
///
/// The important contract is separation of concerns: base autocomplete rules stay stable, while
/// optional user writing preferences are normalized once and inserted consistently.
final class CustomAIInstructionFormatterTests: XCTestCase {
    func test_normalized_returnsNilForMissingOrWhitespaceInstructions() {
        XCTAssertNil(CustomAIInstructionFormatter.normalized(nil))
        XCTAssertNil(CustomAIInstructionFormatter.normalized(" \n\t "))
    }

    func test_normalized_trimsMeaningfulInstructions() {
        XCTAssertEqual(
            CustomAIInstructionFormatter.normalized("  Prefer concise replies. \n"),
            "Prefer concise replies."
        )
    }

    func test_promptSectionLines_splitsAndFiltersInstructionLines() {
        let lines = CustomAIInstructionFormatter.promptSectionLines(
            from: " Prefer concise replies. \n\n Match my tone. "
        )

        XCTAssertEqual(
            lines,
            [
                "Custom AI writing preferences:",
                "- Prefer concise replies.",
                "- Match my tone.",
                "Apply this guidance only when it fits the surrounding text.",
                "Do not mention or explain these preferences."
            ]
        )
    }
}

/// Tests for the Apple Intelligence prompt adapter.
///
/// Foundation Models gives Tabby an instructions channel, so these tests lock down which rules go
/// into high-priority instructions and which field-specific text remains in the short prompt.
final class FoundationModelPromptRendererTests: XCTestCase {
    func test_sessionInstructions_includeAutocompleteContractAndRequestPolicies() {
        let request = TabbyTestFixtures.suggestionRequest(
            completionLengthInstruction: "UNIQUE_LENGTH_POLICY",
            customAIInstructions: "UNIQUE_CUSTOM_POLICY"
        )

        let instructions = FoundationModelPromptRenderer.sessionInstructions(for: request)

        XCTAssertTrue(instructions.contains("inline autocomplete engine"))
        XCTAssertTrue(instructions.contains("UNIQUE_LENGTH_POLICY"))
        XCTAssertTrue(instructions.contains("UNIQUE_CUSTOM_POLICY"))
        XCTAssertTrue(instructions.contains("Do not repeat or quote the existing text."))
    }

    func test_prompt_includesApplicationNameAndTrimmedPrefixText() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "  Hello from the field  ",
            precedingText: "  Hello from the field  "
        )

        let prompt = FoundationModelPromptRenderer.prompt(for: request)

        XCTAssertTrue(prompt.contains("App: TestApp"))
        XCTAssertTrue(prompt.contains("Hello from the field"))
        XCTAssertFalse(prompt.contains("  Hello from the field  "))
    }

    func test_prompt_returnsFallbackWhenPrefixIsEmptyAfterTrimming() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: " \n ",
            precedingText: " \n "
        )

        let prompt = FoundationModelPromptRenderer.prompt(for: request)

        XCTAssertEqual(
            prompt,
            "Continue the text at the caret using a short inline completion."
        )
    }
}
