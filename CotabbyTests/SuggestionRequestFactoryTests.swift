import XCTest
@testable import Cotabby

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
        let context = CotabbyTestFixtures.focusedInputContext(
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
            maxPrefixWordsFoundationModel: 9,
            maxPrefixCharactersFoundationModel: 96,
            maxSuffixCharacters: 192,
            defaultUserName: nil,
            defaultWordCountPreset: .sevenToTwelve,
            focusPollIntervalMilliseconds: 50
        )

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: CotabbyTestFixtures.settingsSnapshot(),
            configuration: configuration
        )

        XCTAssertEqual(result.request.prefixText, "zeta eta theta")
        XCTAssertTrue(result.promptPreview.contains("zeta eta theta"))
        XCTAssertFalse(result.promptPreview.contains("alpha beta"))
    }

    /// The Foundation Models path has a separate, larger prefix budget because Apple's shared
    /// context window can take more local sentences without crowding instructions. This pins the
    /// engine-aware truncation so a future change cannot quietly collapse the two budgets back
    /// into one and shrink FM-side context with it.
    func test_buildRequest_appliesFoundationModelPrefixBudgetWhenAppleEngineSelected() {
        let precedingText = "alpha beta gamma delta epsilon zeta eta theta"
        let context = CotabbyTestFixtures.focusedInputContext(precedingText: precedingText)
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
            maxPrefixWordsFoundationModel: 6,
            maxPrefixCharactersFoundationModel: 96,
            maxSuffixCharacters: 192,
            defaultUserName: nil,
            defaultWordCountPreset: .sevenToTwelve,
            focusPollIntervalMilliseconds: 50
        )

        let llamaResult = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: CotabbyTestFixtures.settingsSnapshot(selectedEngine: .llamaOpenSource),
            configuration: configuration
        )
        let foundationModelResult = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: CotabbyTestFixtures.settingsSnapshot(selectedEngine: .appleIntelligence),
            configuration: configuration
        )

        XCTAssertEqual(llamaResult.request.prefixText, "zeta eta theta")
        XCTAssertEqual(
            foundationModelResult.request.prefixText,
            "gamma delta epsilon zeta eta theta"
        )
    }

    func test_buildRequest_usesWordCountPresetForInstructionAndTokenBudget() {
        let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello world")
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
            maxPrefixWordsFoundationModel: 150,
            maxPrefixCharactersFoundationModel: 2500,
            maxSuffixCharacters: 192,
            defaultUserName: nil,
            defaultWordCountPreset: .sevenToTwelve,
            focusPollIntervalMilliseconds: 50
        )

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: CotabbyTestFixtures.settingsSnapshot(selectedWordCountPreset: .twelveToTwenty),
            configuration: configuration
        )

        XCTAssertEqual(
            result.request.completionLengthInstruction,
            "Return only the next 12 to 20 words."
        )
        // 20 (highWords) * 1.3 (English fallback factor) = 26, rounded up.
        XCTAssertEqual(result.request.maxPredictionTokens, 26)
        XCTAssertEqual(result.promptPreview, result.request.prompt)
    }

    func test_buildRequest_carriesProfileAndVisualContextSummary() {
        let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello")

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: CotabbyTestFixtures.settingsSnapshot(
                userName: "Casey"
            ),
            configuration: .standard,
            visualContextSummary: "Calendar window says project review at 3 PM."
        )

        XCTAssertEqual(result.request.userName, "Casey")
        XCTAssertEqual(
            result.request.visualContextSummary,
            "Calendar window says project review at 3 PM."
        )
        XCTAssertTrue(result.promptPreview.contains("Casey"))
        XCTAssertTrue(result.promptPreview.contains("Calendar window says project review at 3 PM."))
    }

    func test_buildRequest_sanitizesVisualContextBeforePromptInjection() {
        let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello")

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: CotabbyTestFixtures.settingsSnapshot(),
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
        let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello")

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: CotabbyTestFixtures.settingsSnapshot(selectedEngine: .appleIntelligence),
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
        let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello")

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: CotabbyTestFixtures.settingsSnapshot(isClipboardContextEnabled: true),
            configuration: .standard,
            clipboardContext: "  Copied project notes.  "
        )

        XCTAssertEqual(result.request.clipboardContext, "Copied project notes.")
        XCTAssertTrue(result.promptPreview.contains("On the clipboard:"))
        XCTAssertTrue(result.promptPreview.contains("Copied project notes."))
    }

    func test_buildRequest_sanitizesClipboardContextBeforePromptInjection() {
        let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello")

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: CotabbyTestFixtures.settingsSnapshot(isClipboardContextEnabled: true),
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
        let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello")

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: CotabbyTestFixtures.settingsSnapshot(isClipboardContextEnabled: false),
            configuration: .standard,
            clipboardContext: "Copied project notes."
        )

        XCTAssertNil(result.request.clipboardContext)
        XCTAssertFalse(result.promptPreview.contains("On the clipboard:"))
        XCTAssertFalse(result.promptPreview.contains("Copied project notes."))
    }

    func test_buildRequest_clipsLongClipboardContext() throws {
        let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello")
        let longClipboard = String(repeating: "a", count: 1_500)

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: CotabbyTestFixtures.settingsSnapshot(isClipboardContextEnabled: true),
            configuration: .standard,
            clipboardContext: longClipboard
        )

        let clipboardContext = try XCTUnwrap(result.request.clipboardContext)
        XCTAssertEqual(clipboardContext.count, 1_200)
        XCTAssertTrue(clipboardContext.hasSuffix("..."))
    }
}
