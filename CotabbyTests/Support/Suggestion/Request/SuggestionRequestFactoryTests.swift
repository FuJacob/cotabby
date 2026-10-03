import XCTest
@testable import Cotabby

/// Tests for the pure request-construction boundary: the should-generate gate, engine-aware prefix
/// truncation, token budgeting, and which optional context (clipboard, screen, surface, notes) is
/// allowed into the prompt for each engine.
final class SuggestionRequestFactoryTests: XCTestCase {
    /// A configuration with small, explicit budgets so truncation and token-floor behavior is
    /// visible in short fixtures. Only the knobs a test varies are parameters.
    private func makeConfiguration(
        maxPredictionTokens: Int = 8,
        maxPrefixWords: Int = 50,
        maxPrefixCharacters: Int = 1000,
        maxPrefixWordsFoundationModel: Int = 150,
        maxPrefixCharactersFoundationModel: Int = 2500
    ) -> SuggestionConfiguration {
        SuggestionConfiguration(
            maxPredictionTokens: maxPredictionTokens,
            debounceMilliseconds: 0,
            temperature: 0.1,
            topK: 20,
            topP: 0.7,
            minP: 0.08,
            repetitionPenalty: 1.05,
            randomSeed: 42,
            maxPrefixWords: maxPrefixWords,
            maxPrefixCharacters: maxPrefixCharacters,
            maxPrefixWordsFoundationModel: maxPrefixWordsFoundationModel,
            maxPrefixCharactersFoundationModel: maxPrefixCharactersFoundationModel,
            maxSuffixCharacters: 192,
            llamaPromptTokenBudget: 1934,
            defaultUserName: nil,
            defaultWordCountPreset: .sevenToTwelve,
            focusPollIntervalMilliseconds: 50
        )
    }

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

    // MARK: - shouldGenerateSuggestion

    /// A request needs at least one non-whitespace character. No trailing space is required:
    /// debounce handles keystroke settling and the output normalizer handles spacing, so adding
    /// "one more guard" here would silently remove completions that used to work.
    /// Budgets within the reserved output ceiling leave the prompt budget alone; larger ones (a
    /// long range with multi-line, up to 120 tokens) take their excess out of the prompt, so the
    /// context window always holds prompt plus the full decode.
    func test_promptTokenBudget_reservesRoomForTheRequestsWholeOutput() {
        let ceiling = SuggestionConfiguration.llamaPromptOutputCeilingTokens
        XCTAssertEqual(SuggestionRequestFactory.promptTokenBudget(configuredBudget: 3982, maxPredictionTokens: 26), 3982)
        XCTAssertEqual(SuggestionRequestFactory.promptTokenBudget(configuredBudget: 3982, maxPredictionTokens: ceiling), 3982)
        XCTAssertEqual(SuggestionRequestFactory.promptTokenBudget(configuredBudget: 3982, maxPredictionTokens: 120), 3982 - (120 - ceiling))
        XCTAssertEqual(SuggestionRequestFactory.promptTokenBudget(configuredBudget: 10, maxPredictionTokens: 120), 0)
    }

    func test_shouldGenerate_requiresNonWhitespaceButNotATrailingDelimiter() {
        for text in ["", "   \t  ", "\n\n", " \n\t \n  "] {
            XCTAssertFalse(SuggestionRequestFactory.shouldGenerateSuggestion(for: text), text.debugDescription)
        }
        for text in ["a", "word", "Hello, wor", "  hello", "hello  ", "今日は"] {
            XCTAssertTrue(SuggestionRequestFactory.shouldGenerateSuggestion(for: text), text.debugDescription)
        }
    }

    /// The opt-in boundary preference waits for a delimiter inside space-delimited words, but must
    /// not starve scripts that never produce one, or code-like tokens the lexical policy ignores.
    func test_boundaryPreferenceWaitsForDelimiterButPreservesUnspacedLanguages() {
        for text in ["w", "word", "Please schedu", "I don't", "Try (wor"] {
            XCTAssertFalse(SuggestionRequestFactory.shouldGenerateSuggestion(for: text, suggestWithinWords: false), text)
        }
        for text in ["word ", "word,", "word.", "word\n", "今日は", "user_name", "version v2"] {
            XCTAssertTrue(SuggestionRequestFactory.shouldGenerateSuggestion(for: text, suggestWithinWords: false), text)
        }
        XCTAssertFalse(SuggestionRequestFactory.shouldGenerateSuggestion(for: "  ", suggestWithinWords: false))
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
        // Sized from the shipped word budget so the window binds on words, not characters.
        let retainedText = String(repeating: "w\n\t", count: SuggestionConfiguration.standard.maxPrefixWords - 1) + "last  \n"
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
        let configuration = makeConfiguration(maxPrefixWords: 3, maxPrefixCharacters: 32)

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
        let configuration = makeConfiguration(
            maxPrefixWords: 3,
            maxPrefixCharacters: 32,
            maxPrefixWordsFoundationModel: 6,
            maxPrefixCharactersFoundationModel: 96
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
        // The endpoint backend is a small-window completion transport like llama, so it shares the
        // llama budget rather than Apple's larger one.
        let endpointResult = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: CotabbyTestFixtures.settingsSnapshot(selectedEngine: .openAICompatible),
            configuration: configuration
        )

        XCTAssertEqual(llamaResult.request.prefixText, "zeta eta theta")
        XCTAssertEqual(endpointResult.request.prefixText, "zeta eta theta")
        XCTAssertEqual(
            foundationModelResult.request.prefixText,
            "gamma delta epsilon zeta eta theta"
        )
    }

    func test_buildRequest_usesWordCountPresetForInstructionAndTokenBudget() {
        let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello world")
        let configuration = makeConfiguration(maxPredictionTokens: 1)

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
        // The writer's name reaches the prompt only where the caret follows a sign-off
        // (`SignOffCue`); "Hello" is an opening, so the name stays out of the preview.
        XCTAssertFalse(result.promptPreview.contains("Casey"))
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

    /// The clipboard cap is 1,200 characters including the "..." marker, and whitespace exposed
    /// by the cut is trimmed before the marker so the clip never reads as "word ...".
    func test_buildRequest_clipsClipboardContextAtItsCharacterCap() throws {
        func clipboard(for raw: String) throws -> String {
            try XCTUnwrap(
                SuggestionRequestFactory.buildRequest(
                    context: CotabbyTestFixtures.focusedInputContext(precedingText: "Hello"),
                    settings: CotabbyTestFixtures.settingsSnapshot(isClipboardContextEnabled: true),
                    configuration: .standard,
                    clipboardContext: raw
                ).request.clipboardContext
            )
        }

        let atCap = String(repeating: "a", count: 1_200)
        XCTAssertEqual(try clipboard(for: atCap), atCap)

        XCTAssertEqual(
            try clipboard(for: String(repeating: "a", count: 1_201)),
            String(repeating: "a", count: 1_197) + "..."
        )

        // The 1,197-character cut lands just after the space, which is trimmed before the marker.
        XCTAssertEqual(
            try clipboard(for: String(repeating: "a", count: 1_196) + " " + String(repeating: "b", count: 10)),
            String(repeating: "a", count: 1_196) + "..."
        )
    }

    /// A clipboard or screen excerpt with no letters or digits carries no conditioning signal, so
    /// it is dropped instead of adding an empty-looking section to the prompt.
    func test_buildRequest_dropsContextWithoutAlphanumericSignal() {
        for raw in ["   \n\t ", "--- +++ ***", "@@ ... @"] {
            let result = SuggestionRequestFactory.buildRequest(
                context: CotabbyTestFixtures.focusedInputContext(precedingText: "Hello"),
                settings: CotabbyTestFixtures.settingsSnapshot(isClipboardContextEnabled: true),
                configuration: .standard,
                clipboardContext: raw,
                visualContextSummary: raw
            )
            XCTAssertNil(result.request.clipboardContext, raw.debugDescription)
            XCTAssertNil(result.request.visualContextSummary, raw.debugDescription)
        }
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

    // MARK: - Token budget

    /// The budget is `ceil(highWords * tokensPerWord)`, floored by the configuration and doubled
    /// (capped at 120) in multi-line mode. A single known response language supplies its own
    /// tokens-per-word factor; none, several, or an unknown language fall back to 1.3.
    func test_buildRequest_maxPredictionTokensCombinesWordRangeLanguageFloorAndMultiLine() {
        struct Case {
            let name: String
            var floor = 5
            var preset: SuggestionWordCountPreset = .sevenToTwelve
            var customRange: SuggestionWordRange?
            var languages: [String] = []
            let expectedSingleLine: Int
            let expectedMultiLine: Int
        }
        let cases = [
            Case(name: "default preset, English fallback", expectedSingleLine: 16, expectedMultiLine: 32),
            Case(name: "Russian factor", preset: .twelveToTwenty, languages: ["Russian"],
                 expectedSingleLine: 40, expectedMultiLine: 80),
            Case(name: "several languages use the fallback", preset: .twelveToTwenty,
                 languages: ["Russian", "German"], expectedSingleLine: 26, expectedMultiLine: 52),
            Case(name: "multi-line doubling is capped at 120",
                 customRange: SuggestionWordRange(lowWords: 50, highWords: 50), languages: ["Russian"],
                 expectedSingleLine: 100, expectedMultiLine: 120),
            Case(name: "configuration floor wins over a short range", floor: 30,
                 expectedSingleLine: 30, expectedMultiLine: 60)
        ]

        for testCase in cases {
            for isMultiLineEnabled in [false, true] {
                let settings = CotabbyTestFixtures.settingsSnapshot(
                    selectedWordCountPreset: testCase.preset,
                    isUsingCustomWordCountRange: testCase.customRange != nil,
                    customWordCountRange: testCase.customRange ?? SuggestionWordRange(lowWords: 5, highWords: 15),
                    responseLanguages: testCase.languages,
                    isMultiLineEnabled: isMultiLineEnabled
                )
                let result = SuggestionRequestFactory.buildRequest(
                    context: CotabbyTestFixtures.focusedInputContext(precedingText: "Hello"),
                    settings: settings,
                    configuration: makeConfiguration(maxPredictionTokens: testCase.floor)
                )
                XCTAssertEqual(
                    result.request.maxPredictionTokens,
                    isMultiLineEnabled ? testCase.expectedMultiLine : testCase.expectedSingleLine,
                    "\(testCase.name), multi-line: \(isMultiLineEnabled)"
                )
                XCTAssertEqual(result.request.isMultiLineEnabled, isMultiLineEnabled, testCase.name)
            }
        }
    }

    /// Sampling knobs and the focus generation flow through unchanged; the factory only decides
    /// content, never engine tuning. Each build also gets its own correlation ID for log joins.
    func test_buildRequest_carriesConfigurationAndGenerationThroughUnchanged() {
        let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello", generation: 7)
        let build = {
            SuggestionRequestFactory.buildRequest(
                context: context,
                settings: CotabbyTestFixtures.settingsSnapshot(responseLanguages: ["Spanish"]),
                configuration: self.makeConfiguration()
            ).request
        }
        let request = build()

        XCTAssertEqual(request.generation, 7)
        XCTAssertEqual(request.context, context)
        XCTAssertEqual(request.temperature, 0.1)
        XCTAssertEqual(request.topK, 20)
        XCTAssertEqual(request.topP, 0.7)
        XCTAssertEqual(request.minP, 0.08)
        XCTAssertEqual(request.repetitionPenalty, 1.05)
        XCTAssertEqual(request.randomSeed, 42)
        XCTAssertEqual(request.maxSuffixCharacters, 192)
        XCTAssertEqual(request.languageInstruction, LanguageCatalog.promptInstruction(for: ["Spanish"]))
        XCTAssertTrue(request.requestID.hasPrefix("req_"))
        XCTAssertNotEqual(request.requestID, build().requestID)
    }

    // MARK: - truncatedPromptPrefix edges

    func test_truncatedPromptPrefix_nonPositiveBudgetsProduceEmptyPrefix() {
        XCTAssertEqual(
            SuggestionRequestFactory.truncatedPromptPrefix(
                from: "Hello world",
                configuration: makeConfiguration(maxPrefixCharacters: 0)
            ),
            ""
        )
        XCTAssertEqual(
            SuggestionRequestFactory.truncatedPromptPrefix(
                from: "Hello world",
                configuration: makeConfiguration(maxPrefixWords: 0)
            ),
            ""
        )
    }

    /// At exactly the word budget the character window is returned verbatim, leading whitespace
    /// included; one word over drops the oldest word together with the whitespace before the next.
    func test_truncatedPromptPrefix_wordBudgetBoundary() {
        let configuration = makeConfiguration(maxPrefixWords: 3)

        XCTAssertEqual(
            SuggestionRequestFactory.truncatedPromptPrefix(from: "\n  one two three", configuration: configuration),
            "\n  one two three"
        )
        XCTAssertEqual(
            SuggestionRequestFactory.truncatedPromptPrefix(from: "zero\n\none two three ", configuration: configuration),
            "one two three "
        )
    }

    /// The character window is applied first and can start mid-word; the word budget does not
    /// repair that partial leading word when the window is already within budget.
    func test_truncatedPromptPrefix_characterWindowMayStartMidWord() {
        XCTAssertEqual(
            SuggestionRequestFactory.truncatedPromptPrefix(
                from: "abcdef ghi",
                configuration: makeConfiguration(maxPrefixCharacters: 6)
            ),
            "ef ghi"
        )
    }

    func test_shouldGenerateSuggestion_declinesACaretInsideAToken() {
        XCTAssertFalse(SuggestionRequestFactory.shouldGenerateSuggestion(for: "head", trailingText: "phones"))
        XCTAssertFalse(SuggestionRequestFactory.shouldGenerateSuggestion(for: "jane", trailingText: "@example.com"))
        XCTAssertTrue(SuggestionRequestFactory.shouldGenerateSuggestion(for: "Thanks", trailingText: ". Bye"))
        XCTAssertTrue(SuggestionRequestFactory.shouldGenerateSuggestion(for: "Thanks for", trailingText: ""))
    }

    func test_buildRequest_carriesTheWordRange() {
        let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Thanks so much, I really ")
        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: CotabbyTestFixtures.settingsSnapshot(),
            configuration: .standard
        )
        XCTAssertNotNil(result.request.wordRange)
    }

    /// Measured 2026-09-11 in a Chrome page modelled on Claude's composer: three paragraphs reached the
    /// model as "one line. The second paragraph starts here and A third one".
    func testTheWindowKeepsLineAndParagraphBreaks() {
        let text = "Hi Sam,\n\nThanks for the update.\nBest"
        XCTAssertEqual(
            SuggestionRequestFactory.truncatedPromptPrefix(from: text, configuration: .standard, engine: .llamaOpenSource),
            text
        )
    }
}
