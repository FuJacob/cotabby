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
            defaultCustomAIInstructions: nil,
            defaultWordCountPreset: .sevenToTwelve
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
            defaultCustomAIInstructions: nil,
            defaultWordCountPreset: .sevenToTwelve
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

    func test_buildRequest_carriesCustomInstructionsAndVisualContextSummary() {
        let context = TabbyTestFixtures.focusedInputContext(precedingText: "Hello")

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: TabbyTestFixtures.settingsSnapshot(
                customAIInstructions: "Prefer direct wording."
            ),
            configuration: .standard,
            visualContextSummary: "Calendar window says project review at 3 PM."
        )

        XCTAssertEqual(result.request.customAIInstructions, "Prefer direct wording.")
        XCTAssertEqual(
            result.request.visualContextSummary,
            "Calendar window says project review at 3 PM."
        )
        XCTAssertTrue(result.promptPreview.contains("Prefer direct wording."))
        XCTAssertTrue(result.promptPreview.contains("Calendar window says project review at 3 PM."))
    }
}
