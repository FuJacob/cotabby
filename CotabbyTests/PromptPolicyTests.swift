import XCTest
@testable import Cotabby

/// Tests for the Apple Intelligence prompt adapter.
///
/// Foundation Models gives Cotabby an instructions channel, so these tests lock down which rules go
/// into high-priority instructions and which field-specific text remains in the short prompt.
final class FoundationModelPromptRendererTests: XCTestCase {
    func test_sessionInstructions_declarePositiveContinuationIdentityAndOutputContract() {
        let request = CotabbyTestFixtures.suggestionRequest(
            completionLengthInstruction: "UNIQUE_LENGTH_POLICY",
            userName: "UNIQUE_PROFILE_NAME"
        )

        let instructions = FoundationModelPromptRenderer.sessionInstructions(for: request)

        // Positive identity: name what the model *is*, not what it isn't.
        XCTAssertTrue(instructions.contains("complete partially-typed text"))
        // Output contract folds the anti-greeting / anti-markdown / anti-quote rules into one
        // forbidden-content line, anchored on "Output the continuation only:" so a future
        // wording change cannot silently drop a rule.
        XCTAssertTrue(instructions.contains("Output the continuation only:"))
        XCTAssertTrue(instructions.contains("no greeting"))
        XCTAssertTrue(instructions.contains("no sign-off"))
        XCTAssertTrue(instructions.contains("no quotes"))
        XCTAssertTrue(instructions.contains("no markdown"))
        XCTAssertTrue(instructions.contains("no labels"))
        XCTAssertTrue(instructions.contains("no explanation"))
        // Style line still has to match the existing field — language, register, casing.
        XCTAssertTrue(instructions.contains("Match the existing language, register, casing"))
        // The word-range cue is still token-budget-only on both engines.
        XCTAssertFalse(instructions.contains("UNIQUE_LENGTH_POLICY"))
    }

    /// Locks in the anti-echo rule. Without it, the chat-tuned model emits the prefix back on some
    /// mid-line comment and mid-sentence prose cases — the normalizer then strips the echo and the
    /// overlay shows nothing. The eval suite (`FoundationModelDriftEvalTests`) was the canary that
    /// surfaced this regression when session reuse was tightened to single-turn, so it stays
    /// pinned here as a fast unit-level guard before the live eval ever runs.
    func test_sessionInstructions_forbidEchoingExistingText() {
        let request = CotabbyTestFixtures.suggestionRequest()

        let instructions = FoundationModelPromptRenderer.sessionInstructions(for: request)

        XCTAssertTrue(instructions.contains("Continue from the position immediately after the existing text"))
        XCTAssertTrue(instructions.contains("Do not repeat or quote the existing text"))
    }

    /// The user's name is deliberately withheld from Apple's chat-tuned model: a stated name is the
    /// main trigger for breaking character ("Jacob, how are you"). Personalization stays on llama.
    func test_sessionInstructions_omitTheUserName() {
        let request = CotabbyTestFixtures.suggestionRequest(userName: "UNIQUE_PROFILE_NAME")

        let instructions = FoundationModelPromptRenderer.sessionInstructions(for: request)

        XCTAssertFalse(instructions.contains("UNIQUE_PROFILE_NAME"))
    }

    /// The few-shot set was trimmed from five demonstrations to two on purpose — one
    /// prose-with-salutation and one code — so this test pins both presence *and* count to keep
    /// future edits from silently growing the set back.
    func test_sessionInstructions_includeExactlyTwoContinuationExamples() {
        let request = CotabbyTestFixtures.suggestionRequest()

        let instructions = FoundationModelPromptRenderer.sessionInstructions(for: request)

        XCTAssertTrue(instructions.contains("Examples ("))
        // Scope the "Continuation:" count to the examples block so an injected
        // language hint or custom rule containing the substring cannot inflate it.
        let examplesHeader = "Examples (quotes only mark the boundaries; never output the quotes):"
        let examplesSection = instructions
            .components(separatedBy: examplesHeader)
            .dropFirst()
            .joined(separator: examplesHeader)
        let continuationCount = examplesSection.components(separatedBy: "Continuation:").count - 1
        XCTAssertEqual(continuationCount, 2, "Expected the trimmed two-example demo set.")
    }

    func test_prompt_includesApplicationNameAndPreservesPrefixText() {
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: "  Hello from the field  ",
            precedingText: "  Hello from the field  "
        )

        let prompt = FoundationModelPromptRenderer.prompt(for: request)

        XCTAssertTrue(prompt.contains("User is on TestApp."))
        XCTAssertTrue(prompt.contains("  Hello from the field  "))
    }

    /// Trailing context lets the model bridge into what is already after the caret instead of
    /// overwriting it. The section appears only when there is suffix content to share.
    func test_prompt_includesTrailingTextSectionWhenSuffixPresent() {
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: "I'm flying to ",
            precedingText: "I'm flying to ",
            trailingText: " on Friday."
        )

        let prompt = FoundationModelPromptRenderer.prompt(for: request)

        XCTAssertTrue(prompt.contains("Text after the caret:"))
        XCTAssertTrue(prompt.contains(" on Friday."))
    }

    func test_prompt_omitsTrailingTextSectionWhenSuffixEmpty() {
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: "Continue this",
            precedingText: "Continue this"
        )

        let prompt = FoundationModelPromptRenderer.prompt(for: request)

        XCTAssertFalse(prompt.contains("Text after the caret:"))
    }

    /// The natural-language length hint goes on the prompt channel (per-request), not the
    /// instructions channel (which is cached on the FM session). That keeps the cached prefix
    /// stable while still giving the model the cue it needs to stop at a clean word boundary.
    func test_prompt_includesNaturalLanguageLengthHint() {
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: "Continue this",
            precedingText: "Continue this",
            completionLengthInstruction: "Return only the next 7 to 12 words."
        )

        let prompt = FoundationModelPromptRenderer.prompt(for: request)

        XCTAssertTrue(prompt.contains("Return only the next 7 to 12 words."))
    }

    /// Per-app tone hints live in the prompt rather than instructions so switching apps does not
    /// invalidate the cached instruction prefix. Use a known code-editor bundle ID and verify the
    /// matching cue appears; unknown bundle IDs fall through to no hint at all.
    func test_prompt_includesCodeEditorToneHintForKnownBundleIdentifier() {
        let context = CotabbyTestFixtures.focusedInputContext(
            applicationName: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode",
            precedingText: "let total = items.reduce(0, "
        )
        let request = SuggestionRequest(
            context: context,
            prefixText: "let total = items.reduce(0, ",
            prompt: "PROMPT",
            generation: 1,
            maxPredictionTokens: 16,
            temperature: 0.1,
            topK: 20,
            topP: 0.7,
            minP: 0.08,
            repetitionPenalty: 1.05,
            randomSeed: 42,
            maxSuffixCharacters: 192,
            completionLengthInstruction: "Return only the next 7 to 12 words.",
            userName: nil,
            customRules: [],
            languageInstruction: nil,
            clipboardContext: nil,
            visualContextSummary: nil,
            isMultiLineEnabled: false
        )

        let prompt = FoundationModelPromptRenderer.prompt(for: request)

        XCTAssertTrue(prompt.contains("writing code"))
    }

    /// Terminal emulators host prose contexts (commit messages, log pagers, shell prompts) more
    /// often than not, so they must not pick up the code-editor tone hint. Cursor is also
    /// excluded because its ToDesktop bundle hash is unstable across releases.
    func test_prompt_omitsCodeEditorToneHintForTerminalAndOpaqueCursorBundles() {
        let bundles = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "co.zeit.hyper",
            "com.todesktop.230313mzl4w4u92"
        ]
        for bundle in bundles {
            let context = CotabbyTestFixtures.focusedInputContext(
                applicationName: "Test",
                bundleIdentifier: bundle,
                precedingText: "anything"
            )
            let request = SuggestionRequest(
                context: context,
                prefixText: "anything",
                prompt: "PROMPT",
                generation: 1,
                maxPredictionTokens: 16,
                temperature: 0.1,
                topK: 20,
                topP: 0.7,
                minP: 0.08,
                repetitionPenalty: 1.05,
                randomSeed: 42,
                maxSuffixCharacters: 192,
                completionLengthInstruction: "Return only the next 7 to 12 words.",
                userName: nil,
                customRules: [],
                languageInstruction: nil,
                clipboardContext: nil,
                visualContextSummary: nil,
                isMultiLineEnabled: false
            )

            let prompt = FoundationModelPromptRenderer.prompt(for: request)
            XCTAssertFalse(prompt.contains("writing code"), "bundle \(bundle) should not get the code-editor hint")
        }
    }

    func test_prompt_omitsToneHintForUnknownBundleIdentifier() {
        let request = CotabbyTestFixtures.suggestionRequest(
            prefixText: "Continue this",
            precedingText: "Continue this"
        )

        let prompt = FoundationModelPromptRenderer.prompt(for: request)

        // The default fixture uses bundleIdentifier "com.example.TestApp", which is not in any of
        // the tone-hint prefix sets, so the prompt must not carry a category cue.
        XCTAssertFalse(prompt.contains("writing code"))
        XCTAssertFalse(prompt.contains("writing an email"))
        XCTAssertFalse(prompt.contains("chat app"))
        XCTAssertFalse(prompt.contains("inside a browser"))
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
        XCTAssertTrue(preview.contains("Prompt:\n"))
        XCTAssertTrue(preview.contains("UNIQUE_APPLE_SCREEN_CONTEXT"))
        // The length cue lives on the prompt channel now (PR 5), so it must surface in diagnostics.
        XCTAssertTrue(preview.contains("UNIQUE_LENGTH_POLICY"))
        // It still must not bleed into the cached instructions channel.
        let instructions = FoundationModelPromptRenderer.sessionInstructions(for: request)
        XCTAssertFalse(instructions.contains("UNIQUE_LENGTH_POLICY"))
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
            llamaEngine: openSourceEngine,
            performanceMetricsStore: PerformanceMetricsStore(userDefaults: makeUserDefaults()),
            llamaModelNameProvider: { nil }
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
