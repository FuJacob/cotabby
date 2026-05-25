import XCTest
@testable import Cotabby

/// Tests for the Apple Intelligence prompt adapter.
///
/// Foundation Models gives Cotabby an instructions channel, so these tests lock down which rules go
/// into high-priority instructions and which field-specific text remains in the short prompt.
final class FoundationModelPromptRendererTests: XCTestCase {
    func test_sessionInstructions_includeAutocompleteContractAndRequestPolicies() {
        let request = CotabbyTestFixtures.suggestionRequest(
            completionLengthInstruction: "UNIQUE_LENGTH_POLICY",
            userName: "UNIQUE_PROFILE_NAME"
        )

        let instructions = FoundationModelPromptRenderer.sessionInstructions(for: request)

        XCTAssertTrue(instructions.contains("text-continuation engine"))
        XCTAssertTrue(instructions.contains("UNIQUE_LENGTH_POLICY"))
        XCTAssertTrue(instructions.contains("Do not repeat or quote the existing text."))
    }

    /// The user's name is deliberately withheld from Apple's chat-tuned model: a stated name is the
    /// main trigger for breaking character ("Jacob, how are you"). Personalization stays on llama.
    func test_sessionInstructions_omitTheUserName() {
        let request = CotabbyTestFixtures.suggestionRequest(userName: "UNIQUE_PROFILE_NAME")

        let instructions = FoundationModelPromptRenderer.sessionInstructions(for: request)

        XCTAssertFalse(instructions.contains("UNIQUE_PROFILE_NAME"))
    }

    /// Few-shot examples are the primary anti-drift mechanism, so guard their presence.
    func test_sessionInstructions_includeContinuationExamples() {
        let request = CotabbyTestFixtures.suggestionRequest()

        let instructions = FoundationModelPromptRenderer.sessionInstructions(for: request)

        XCTAssertTrue(instructions.contains("Examples ("))
        XCTAssertTrue(instructions.contains("Continuation:"))
    }

    func test_prompt_includesApplicationNameAndPreservesPrefixText() {
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: "  Hello from the field  ",
            precedingText: "  Hello from the field  "
        )

        let prompt = FoundationModelPromptRenderer.prompt(for: request)

        XCTAssertTrue(prompt.contains("App: TestApp"))
        XCTAssertTrue(prompt.contains("  Hello from the field  "))
    }

    func test_prompt_includesVisualContextWhenProvided() {
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: "Continue this",
            visualContextSummary: "UNIQUE_APPLE_SCREEN_CONTEXT"
        )

        let prompt = FoundationModelPromptRenderer.prompt(for: request)

        XCTAssertTrue(prompt.contains("Screen content:"))
        XCTAssertTrue(prompt.contains("UNIQUE_APPLE_SCREEN_CONTEXT"))
    }

    func test_prompt_includesClipboardContextWhenProvided() {
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: "Continue this",
            clipboardContext: "UNIQUE_APPLE_CLIPBOARD_MARKER"
        )

        let prompt = FoundationModelPromptRenderer.prompt(for: request)

        XCTAssertTrue(prompt.contains("User's clipboard:"))
        XCTAssertTrue(prompt.contains("UNIQUE_APPLE_CLIPBOARD_MARKER"))
    }

    func test_prompt_returnsFallbackWhenPrefixIsEmptyAfterTrimming() {
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: " \n ",
            precedingText: " \n "
        )

        let prompt = FoundationModelPromptRenderer.prompt(for: request)

        XCTAssertEqual(
            prompt,
            "Continue the text at the caret using a short inline completion."
        )
    }

    func test_promptPreview_includesInstructionsAndPromptPayload() {
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: "Continue this",
            completionLengthInstruction: "UNIQUE_LENGTH_POLICY",
            visualContextSummary: "UNIQUE_APPLE_SCREEN_CONTEXT"
        )

        let preview = FoundationModelPromptRenderer.promptPreview(for: request)

        XCTAssertTrue(preview.contains("Instructions:\n"))
        XCTAssertTrue(preview.contains("UNIQUE_LENGTH_POLICY"))
        XCTAssertTrue(preview.contains("Prompt:\n"))
        XCTAssertTrue(preview.contains("UNIQUE_APPLE_SCREEN_CONTEXT"))
    }
}

@MainActor
final class SuggestionEngineRouterTests: XCTestCase {
    func test_generateSuggestion_fallsBackToOpenSourceWhenAppleRejectsLanguageOrLocale() async throws {
        let settings = SuggestionSettingsModel(
            configuration: .standard,
            userDefaults: makeUserDefaults()
        )
        settings.selectEngine(.appleIntelligence)
        let request = CotabbyTestFixtures.suggestionRequest()
        let fallbackResult = SuggestionResult(
            generation: request.generation,
            rawText: "fallback raw",
            text: "fallback text",
            latency: 0.1
        )
        let appleEngine = StubSuggestionEngine(
            behavior: .failure(
                SuggestionClientError.unsupportedLanguageOrLocale("Apple language failure.")
            )
        )
        let openSourceEngine = StubSuggestionEngine(behavior: .success(fallbackResult))
        let router = SuggestionEngineRouter(
            suggestionSettings: settings,
            foundationModelEngine: appleEngine,
            llamaEngine: openSourceEngine
        )

        let result = try await router.generateSuggestion(for: request)

        XCTAssertEqual(result, fallbackResult)
        XCTAssertEqual(appleEngine.generateCallCount, 1)
        XCTAssertEqual(openSourceEngine.generateCallCount, 1)
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "SuggestionEngineRouterTests-\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected an isolated UserDefaults suite")
            return .standard
        }

        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }
}

@MainActor
private final class StubSuggestionEngine: SuggestionGenerating {
    enum Behavior {
        case success(SuggestionResult)
        case failure(Error)
    }

    private let behavior: Behavior
    private(set) var generateCallCount = 0

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        generateCallCount += 1

        switch behavior {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }

    func resetCachedGenerationContext() async {}
}
