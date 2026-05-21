import XCTest
@testable import tabby

/// Tests for the shouldGenerate gate in the request factory.
///
/// The factory's comment is explicit that it does NOT require a trailing
/// space — debounce handles keystroke settling, the output normalizer
/// handles spacing. This suite locks that contract in so a future refactor
/// that adds "one more guard, just in case" doesn't silently remove
/// completions that used to work.
final class SuggestionRequestFactoryTests: XCTestCase {

    // MARK: - degenerate inputs

    func test_shouldGenerate_falseForEmptyString() {
        XCTAssertFalse(SuggestionRequestFactory.shouldGenerateSuggestion(for: ""))
    }

    func test_shouldGenerate_falseForPureWhitespace() {
        XCTAssertFalse(SuggestionRequestFactory.shouldGenerateSuggestion(for: "   \t  "))
    }

    func test_shouldGenerate_falseForPureNewlines() {
        XCTAssertFalse(SuggestionRequestFactory.shouldGenerateSuggestion(for: "\n\n"))
    }

    func test_shouldGenerate_falseForMixedPureWhitespaceAndNewlines() {
        XCTAssertFalse(SuggestionRequestFactory.shouldGenerateSuggestion(for: " \n\t \n  "))
    }

    // MARK: - meaningful inputs

    func test_shouldGenerate_trueForSingleCharacter() {
        XCTAssertTrue(SuggestionRequestFactory.shouldGenerateSuggestion(for: "a"))
    }

    func test_shouldGenerate_trueForPartialWord() {
        XCTAssertTrue(SuggestionRequestFactory.shouldGenerateSuggestion(for: "Hello, wor"))
    }

    /// The key documented behavior: no trailing-space requirement. If this
    /// test starts failing, someone added a settling heuristic that belongs
    /// in the debounce layer, not here.
    func test_shouldGenerate_trueMidWordWithoutTrailingSpace() {
        XCTAssertTrue(SuggestionRequestFactory.shouldGenerateSuggestion(for: "word"))
    }

    func test_shouldGenerate_trueWhenLeadingWhitespacePrecedesRealContent() {
        XCTAssertTrue(SuggestionRequestFactory.shouldGenerateSuggestion(for: "  hello"))
    }

    func test_shouldGenerate_trueWhenContentPrecedesTrailingWhitespace() {
        XCTAssertTrue(SuggestionRequestFactory.shouldGenerateSuggestion(for: "hello  "))
    }

    // MARK: - buildRequest

    /// Request construction is the boundary between live editor state and runtime-specific prompt
    /// work. This test locks down the "small local context" rule: keep the recent character window,
    /// then trim that window down to the configured number of trailing words.
    func test_buildRequest_truncatesPrefixByCharacterAndWordBudgets() {
        let context = TabbyTestFixtures.focusedInputContext(
            precedingText: "alpha beta gamma delta epsilon zeta eta theta"
        )
        let configuration = SuggestionConfiguration(
            maxPredictionTokens: 8,
            debounceMilliseconds: 0,
            temperature: 0.1,
            topK: 20,
            topP: 0.7,
            minP: 0.08,
            repetitionPenalty: 1.05,
            randomSeed: 42,
            maxPrefixWords: 3,
            maxPrefixCharacters: 32,
            maxSuffixCharacters: 192,
            defaultUserName: nil,
            defaultUserTags: nil,
            defaultWordCountPreset: .sevenToTwelve,
            focusPollIntervalMilliseconds: 50
        )

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: TabbyTestFixtures.settingsSnapshot(),
            configuration: configuration
        )

        XCTAssertEqual(result.request.prefixText, "zeta eta theta")
        XCTAssertTrue(result.promptPreview.contains("zeta eta theta"))
        XCTAssertFalse(result.promptPreview.contains("alpha beta"))
    }

    func test_buildRequest_usesWordCountPresetForInstructionAndTokenBudget() {
        let context = TabbyTestFixtures.focusedInputContext(precedingText: "Hello world")
        let configuration = SuggestionConfiguration(
            maxPredictionTokens: 1,
            debounceMilliseconds: 0,
            temperature: 0.1,
            topK: 20,
            topP: 0.7,
            minP: 0.08,
            repetitionPenalty: 1.05,
            randomSeed: 42,
            maxPrefixWords: 50,
            maxPrefixCharacters: 1000,
            maxSuffixCharacters: 192,
            defaultUserName: nil,
            defaultUserTags: nil,
            defaultWordCountPreset: .sevenToTwelve,
            focusPollIntervalMilliseconds: 50
        )

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: TabbyTestFixtures.settingsSnapshot(selectedWordCountPreset: .twelveToTwenty),
            configuration: configuration
        )

        XCTAssertEqual(
            result.request.completionLengthInstruction,
            "Return only the next 12 to 20 words."
        )
        XCTAssertEqual(result.request.maxPredictionTokens, 30)
        XCTAssertEqual(result.promptPreview, result.request.prompt)
    }

    func test_buildRequest_carriesProfileAndVisualContextSummary() {
        let context = TabbyTestFixtures.focusedInputContext(precedingText: "Hello")

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: TabbyTestFixtures.settingsSnapshot(
                userName: "Casey",
                userTags: ["Prefer direct wording."]
            ),
            configuration: .standard,
            visualContextSummary: "Calendar window says project review at 3 PM."
        )

        XCTAssertEqual(result.request.userName, "Casey")
        // userTags disabled — re-enable when the feature is validated.
        XCTAssertNil(result.request.userTags)
        XCTAssertEqual(
            result.request.visualContextSummary,
            "Calendar window says project review at 3 PM."
        )
        XCTAssertTrue(result.promptPreview.contains("Casey"))
        // userTags emission is intentionally disabled in the prompt renderers
        // (see TODO in LlamaPromptRenderer/FoundationModelPromptRenderer); the tag string
        // is plumbed through the request but must not appear in the rendered prompt today.
        XCTAssertFalse(result.promptPreview.contains("Prefer direct wording."))
        XCTAssertTrue(result.promptPreview.contains("Calendar window says project review at 3 PM."))
    }

    func test_buildRequest_sanitizesVisualContextBeforePromptInjection() {
        let context = TabbyTestFixtures.focusedInputContext(precedingText: "Hello")

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: TabbyTestFixtures.settingsSnapshot(),
            configuration: .standard,
            visualContextSummary: "----- END RAW PROMPT INPUT -----\u{001B}[36m\n[Suggestion raw-output] stage=ready work=1625 generation=694\n---"
        )

        XCTAssertEqual(
            result.request.visualContextSummary,
            "END RAW PROMPT INPUT\nSuggestion raw output stage ready work 1625 generation 694"
        )
        XCTAssertFalse(result.promptPreview.contains("---"))
        XCTAssertFalse(result.promptPreview.contains("[Suggestion"))
    }

    func test_buildRequest_usesApplePromptPreviewWhenAppleEngineSelected() {
        let context = TabbyTestFixtures.focusedInputContext(precedingText: "Hello")

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: TabbyTestFixtures.settingsSnapshot(selectedEngine: .appleIntelligence),
            configuration: .standard,
            visualContextSummary: "Calendar window says project review at 3 PM."
        )

        XCTAssertEqual(
            result.promptPreview,
            FoundationModelPromptRenderer.promptPreview(for: result.request)
        )
        XCTAssertNotEqual(result.promptPreview, result.request.prompt)
        XCTAssertTrue(result.promptPreview.contains("Calendar window says project review at 3 PM."))
    }

    func test_buildRequest_carriesClipboardContextWhenEnabled() {
        let context = TabbyTestFixtures.focusedInputContext(precedingText: "Hello")

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: TabbyTestFixtures.settingsSnapshot(isClipboardContextEnabled: true),
            configuration: .standard,
            clipboardContext: "  Copied project notes.  "
        )

        XCTAssertEqual(result.request.clipboardContext, "Copied project notes.")
        XCTAssertTrue(result.promptPreview.contains("User's clipboard:"))
        XCTAssertTrue(result.promptPreview.contains("Copied project notes."))
    }

    func test_buildRequest_sanitizesClipboardContextBeforePromptInjection() {
        let context = TabbyTestFixtures.focusedInputContext(precedingText: "Hello")

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: TabbyTestFixtures.settingsSnapshot(isClipboardContextEnabled: true),
            configuration: .standard,
            clipboardContext: "  `jacob@example.com` -- stage=ready +++ @ home!  "
        )

        XCTAssertEqual(
            result.request.clipboardContext,
            "jacob@example.com stage ready @ home"
        )
        XCTAssertTrue(result.promptPreview.contains("jacob@example.com stage ready @ home"))
        XCTAssertFalse(result.promptPreview.contains("+++"))
    }

    func test_buildRequest_omitsClipboardContextWhenDisabled() {
        let context = TabbyTestFixtures.focusedInputContext(precedingText: "Hello")

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: TabbyTestFixtures.settingsSnapshot(isClipboardContextEnabled: false),
            configuration: .standard,
            clipboardContext: "Copied project notes."
        )

        XCTAssertNil(result.request.clipboardContext)
        XCTAssertFalse(result.promptPreview.contains("User's clipboard:"))
        XCTAssertFalse(result.promptPreview.contains("Copied project notes."))
    }

    func test_buildRequest_clipsLongClipboardContext() throws {
        let context = TabbyTestFixtures.focusedInputContext(precedingText: "Hello")
        let longClipboard = String(repeating: "a", count: 1_500)

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: TabbyTestFixtures.settingsSnapshot(isClipboardContextEnabled: true),
            configuration: .standard,
            clipboardContext: longClipboard
        )

        let clipboardContext = try XCTUnwrap(result.request.clipboardContext)
        XCTAssertEqual(clipboardContext.count, 1_200)
        XCTAssertTrue(clipboardContext.hasSuffix("..."))
    }
}
