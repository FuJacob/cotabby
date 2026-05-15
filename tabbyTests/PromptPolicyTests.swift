import XCTest
@testable import tabby

/// Tests for the Apple Intelligence prompt adapter.
///
/// Foundation Models gives Tabby an instructions channel, so these tests lock down which rules go
/// into high-priority instructions and which field-specific text remains in the short prompt.
final class FoundationModelPromptRendererTests: XCTestCase {
    func test_sessionInstructions_includeAutocompleteContractAndRequestPolicies() {
        let request = TabbyTestFixtures.suggestionRequest(
            completionLengthInstruction: "UNIQUE_LENGTH_POLICY",
            userName: "UNIQUE_PROFILE_NAME",
            userTags: ["UNIQUE_PROFILE_TAG"]
        )

        let instructions = FoundationModelPromptRenderer.sessionInstructions(for: request)

        XCTAssertTrue(instructions.contains("inline autocomplete engine"))
        XCTAssertTrue(instructions.contains("UNIQUE_LENGTH_POLICY"))
        XCTAssertTrue(instructions.contains("UNIQUE_PROFILE_NAME"))
        XCTAssertTrue(instructions.contains("UNIQUE_PROFILE_TAG"))
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

    func test_prompt_includesClipboardContextWhenProvided() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "Continue this",
            clipboardContext: "UNIQUE_APPLE_CLIPBOARD_MARKER"
        )

        let prompt = FoundationModelPromptRenderer.prompt(for: request)

        XCTAssertTrue(prompt.contains("User's clipboard:"))
        XCTAssertTrue(prompt.contains("UNIQUE_APPLE_CLIPBOARD_MARKER"))
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
