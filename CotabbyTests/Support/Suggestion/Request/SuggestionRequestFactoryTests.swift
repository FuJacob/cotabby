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
    func test_localScreenContextExceedsOldCapButEndpointKeepsLegacyPrompt() {
        let screen = String(repeating: "Project discussion and meeting agenda. ", count: 120)
        for engine in [SuggestionEngineKind.llamaOpenSource, .appleIntelligence, .openAICompatible] {
            let result = SuggestionRequestFactory.buildRequest(
                context: CotabbyTestFixtures.focusedInputContext(precedingText: "Please send "),
                settings: CotabbyTestFixtures.settingsSnapshot(selectedEngine: engine),
                configuration: .standard, visualContextSummary: screen
            )
            let limit = engine == .openAICompatible ? 1500 : 4000
            XCTAssertLessThanOrEqual(result.request.visualContextSummary?.count ?? 0, limit)
            if engine == .openAICompatible {
                XCTAssertLessThan(result.request.prompt.count, 800)
                XCTAssertFalse(VisualContextConfiguration.forEngine(engine).capturesEntireWindow)
            } else {
                XCTAssertGreaterThan(result.request.visualContextSummary?.count ?? 0, 1500)
                XCTAssertGreaterThan(result.request.prompt.count, 1000)
                XCTAssertTrue(VisualContextConfiguration.forEngine(engine).capturesEntireWindow)
            }
            XCTAssertTrue(result.request.prompt.hasSuffix("Please send "))
        }
    }

    func test_denseUnicodeScreenTextLeavesRoomForLocalInstructionsAndCaret() {
        let result = SuggestionRequestFactory.buildRequest(
            context: CotabbyTestFixtures.focusedInputContext(precedingText: "今天"),
            settings: CotabbyTestFixtures.settingsSnapshot(selectedEngine: .appleIntelligence),
            configuration: .standard, visualContextSummary: String(repeating: "请在周五之前发送项目报告", count: 500)
        )
        XCTAssertLessThan(result.request.visualContextSummary?.count ?? 0, 600)
        XCTAssertTrue(result.request.prompt.hasSuffix("今天"))
    }

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

    func test_buildRequest_preservesDocumentStructureAndExactCaretBoundary() {
        let text = "\tHello Casey,\n\nThe agenda:\n  - first item\n  - "
        for engine in [SuggestionEngineKind.llamaOpenSource, .appleIntelligence, .openAICompatible] {
            let result = SuggestionRequestFactory.buildRequest(
                context: CotabbyTestFixtures.focusedInputContext(precedingText: text),
                settings: CotabbyTestFixtures.settingsSnapshot(selectedEngine: engine),
                configuration: .standard
            )
            XCTAssertEqual(result.request.prefixText, text)
            XCTAssertTrue(result.request.prompt.hasSuffix(text))
        }
    }

    func test_truncatedPromptPrefix_preservesSeparatorsWhenWordBudgetDropsOldText() {
        let retainedText = String(repeating: "word\n\t", count: 149) + "last  \n"
        let text = "discard this " + retainedText
        let prefix = SuggestionRequestFactory.truncatedPromptPrefix(from: text, configuration: .standard)
        XCTAssertEqual(prefix, retainedText)
    }

    func test_truncatedPromptPrefix_characterWindowKeepsUnicodeAndTrailingWhitespace() {
        let text = String(repeating: "👩🏽‍💻", count: 2_600) + "\n\tHello  "
        let prefix = SuggestionRequestFactory.truncatedPromptPrefix(from: text, configuration: .standard)
        XCTAssertEqual(prefix, String(text.suffix(SuggestionConfiguration.standard.maxPrefixCharacters)))
        XCTAssertTrue(prefix.hasSuffix("\n\tHello  "))
    }

    func test_buildRequest_boundsFollowingTextForLocalCompletion() {
        let boundedSuffix = String(repeating: "x", count: SuggestionConfiguration.standard.maxSuffixCharacters)
        let context = CotabbyTestFixtures.focusedInputContext(
            precedingText: "We are meeting ",
            trailingText: boundedSuffix + "UNBOUNDED_DOCUMENT_TAIL"
        )
        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: CotabbyTestFixtures.settingsSnapshot(),
            configuration: .standard
        )
        XCTAssertTrue(result.request.prompt.contains("“\(boundedSuffix)”"))
        XCTAssertFalse(result.request.prompt.contains("UNBOUNDED_DOCUMENT_TAIL"))
        XCTAssertTrue(result.request.prompt.hasSuffix("We are meeting "))
    }

    func test_buildRequest_doesNotAddFollowingTextToEndpointPayload() {
        let context = CotabbyTestFixtures.focusedInputContext(
            precedingText: "We are meeting ",
            trailingText: "LOCAL_DOCUMENT_TAIL"
        )
        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: CotabbyTestFixtures.settingsSnapshot(selectedEngine: .openAICompatible),
            configuration: .standard
        )
        XCTAssertFalse(result.request.prompt.contains("LOCAL_DOCUMENT_TAIL"))
        XCTAssertFalse(result.promptPreview.contains("LOCAL_DOCUMENT_TAIL"))
        // Local normalization still needs the suffix to reject duplicate insertions. Excluding
        // it from the transport payload must not remove that safety check's source context.
        XCTAssertEqual(result.request.context.trailingText, "LOCAL_DOCUMENT_TAIL")
    }

    func test_buildRequest_referenceNotesAddContextWithoutRewritingTheWritingSample() {
        let text = "Hey Casey,\n\nQuick update on Matcha: "
        let notes = "Matcha is our internal calendar.\nExample phrasing: Quick update, then next steps."
        let context = CotabbyTestFixtures.focusedInputContext(precedingText: text)
        let bare = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: CotabbyTestFixtures.settingsSnapshot(isSurfaceContextEnabled: false),
            configuration: .standard
        )
        let withNotes = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: CotabbyTestFixtures.settingsSnapshot(
                isSurfaceContextEnabled: false,
                customRules: ["IMPERATIVE_RULE_MUST_STAY_DISABLED"],
                extendedContext: notes
            ),
            configuration: .standard
        )
        // A deterministic context ablation proves which text enters the model, not that a model
        // learned the intended voice. Live typing evaluations must establish that separately.
        XCTAssertEqual(bare.request.prompt, text)
        XCTAssertEqual(withNotes.request.prompt, "Notes the writer keeps in mind: " + notes + "\n\n" + text)
        XCTAssertEqual(withNotes.request.prefixText, bare.request.prefixText)
        XCTAssertTrue(withNotes.request.customRules.isEmpty)
        XCTAssertFalse(withNotes.request.prompt.contains("IMPERATIVE_RULE_MUST_STAY_DISABLED"))
    }

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
            llamaPromptTokenBudget: 1934,
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
            llamaPromptTokenBudget: 1934,
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
            llamaPromptTokenBudget: 1934,
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

    func test_buildRequest_includesSurfaceContextWhenEnabled() {
        let context = CotabbyTestFixtures.focusedInputContext(
            applicationName: "Mail",
            bundleIdentifier: "com.apple.mail",
            precedingText: "Thanks again for",
            windowTitle: "Re: Q3 budget - Mail"
        )

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: CotabbyTestFixtures.settingsSnapshot(),
            configuration: .standard
        )

        XCTAssertEqual(result.request.surfaceContext?.surfaceClass, .email)
        XCTAssertTrue(result.request.prompt.contains("Format: email; App: Mail;"))
        XCTAssertTrue(
            result.request.prompt.contains("Title: Re: Q3 budget."),
            "the app-name suffix is stripped from the title before it reaches the prompt"
        )
        XCTAssertTrue(result.request.prompt.hasSuffix("Thanks again for"))
    }

    func test_buildRequest_omitsSurfaceContextWhenDisabled() {
        let context = CotabbyTestFixtures.focusedInputContext(
            applicationName: "Mail",
            bundleIdentifier: "com.apple.mail",
            precedingText: "Thanks again for",
            windowTitle: "Re: Q3 budget"
        )

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: CotabbyTestFixtures.settingsSnapshot(isSurfaceContextEnabled: false),
            configuration: .standard
        )

        XCTAssertNil(result.request.surfaceContext)
        XCTAssertFalse(result.request.prompt.contains("Format:"))
        XCTAssertFalse(result.request.prompt.contains("Re: Q3 budget"))
    }

    func test_buildRequest_omitsSurfaceContextForCodeEditors() {
        let context = CotabbyTestFixtures.focusedInputContext(
            applicationName: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode",
            precedingText: "// Returns the",
            windowTitle: "Project.swift"
        )

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: CotabbyTestFixtures.settingsSnapshot(),
            configuration: .standard
        )

        XCTAssertNil(result.request.surfaceContext, "app metadata biases base models toward code; editors stay bare")
        XCTAssertFalse(result.request.prompt.contains("Project.swift"))
    }
}
