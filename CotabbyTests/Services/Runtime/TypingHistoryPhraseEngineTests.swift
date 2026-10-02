import XCTest
@testable import Cotabby

@MainActor
final class TypingHistoryPhraseEngineTests: XCTestCase {
    private static var retained: [AnyObject] = []

    private final class FixedHistory: SuggestionHistoryProviding {
        var phrase: String?
        var engines: [SuggestionEngineKind] = []

        func historyExamples(for context: FocusedInputContext, engine: SuggestionEngineKind) -> [String] { [] }
        func phraseContinuation(for request: SuggestionRequest, engine: SuggestionEngineKind) -> String? {
            engines.append(engine)
            return phrase
        }
    }

    private final class CountingEngine: SuggestionGenerating {
        private(set) var calls = 0
        func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
            calls += 1
            return SuggestionResult(generation: request.generation, rawText: " model", text: " model", latency: 0.1)
        }
        func resetCachedGenerationContext() async {}
    }

    private func makeEngine(phrase: String?, engine: SuggestionEngineKind = .appleIntelligence)
        -> (TypingHistoryPhraseEngine, CountingEngine, FixedHistory) {
        let base = CountingEngine()
        let history = FixedHistory()
        history.phrase = phrase
        let wrapper = TypingHistoryPhraseEngine(wrapping: base, history: history, engineKind: { engine })
        Self.retained.append(contentsOf: [base, history, wrapper] as [AnyObject])
        return (wrapper, base, history)
    }

    func test_confidentPhraseAnswersWithoutCallingTheModel() async throws {
        let (engine, base, _) = makeEngine(phrase: " Senad")

        let result = try await engine.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())

        XCTAssertEqual(result.text, " Senad")
        XCTAssertTrue(result.spacingIsExact)
        XCTAssertEqual(base.calls, 0)
    }

    func test_noPhraseFallsThroughToTheModel() async throws {
        let (engine, base, _) = makeEngine(phrase: nil)

        let result = try await engine.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())

        XCTAssertEqual(result.text, " model")
        XCTAssertEqual(base.calls, 1)
    }

    func test_liveEngineKindIsPassedToHistory() async throws {
        let (engine, _, history) = makeEngine(phrase: nil, engine: .openAICompatible)

        _ = try await engine.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())

        XCTAssertEqual(history.engines, [.openAICompatible])
    }
}

final class TypingHistoryPromptTests: XCTestCase {
    func test_basePromptQuotesExamplesBeforeTheCaretText() {
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: "The POC is",
            applicationName: "Mail",
            userName: nil,
            historyExamples: ["The Imperum POC starts Monday."]
        )

        XCTAssertTrue(prompt.contains("Earlier writing by the same author:\n“The Imperum POC starts Monday.”"))
        XCTAssertTrue(prompt.hasSuffix("The POC is"), "The caret text must stay last")
    }

    func test_historySectionIsDroppedWholeRatherThanCutMidQuote() {
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: String(repeating: "word ", count: 30),
            applicationName: "Mail",
            userName: nil,
            historyExamples: [String(repeating: "earlier ", count: 40)],
            contextBudget: 200
        )

        XCTAssertFalse(prompt.contains("“"), "A partly kept history section would leave an unclosed quote")
    }

    func test_basePromptWithoutExamplesIsUnchanged() {
        XCTAssertEqual(
            BaseCompletionPromptRenderer.prompt(prefixText: "The POC is", applicationName: "Mail", userName: nil),
            BaseCompletionPromptRenderer.prompt(
                prefixText: "The POC is", applicationName: "Mail", userName: nil, historyExamples: []
            )
        )
    }

    func test_foundationPromptCarriesExamples() {
        let request = CotabbyTestFixtures.suggestionRequest(historyExamples: ["The Imperum POC starts Monday."])

        let prompt = FoundationModelPromptRenderer.prompt(for: request)

        XCTAssertTrue(prompt.contains("\"The Imperum POC starts Monday.\""))
        XCTAssertFalse(FoundationModelPromptRenderer.sessionInstructions(for: request).contains("Imperum"),
                       "Examples stay out of the cached instructions")
    }

    func test_factoryDropsExamplesForTheEndpointEngine() {
        let context = CotabbyTestFixtures.focusedInputContext(precedingText: "The POC is")
        let examples = ["The Imperum POC starts Monday."]

        let endpoint = SuggestionRequestFactory.buildRequest(
            context: context, settings: CotabbyTestFixtures.settingsSnapshot(selectedEngine: .openAICompatible),
            configuration: .standard, historyExamples: examples
        ).request
        let local = SuggestionRequestFactory.buildRequest(
            context: context, settings: CotabbyTestFixtures.settingsSnapshot(selectedEngine: .llamaOpenSource),
            configuration: .standard, historyExamples: examples
        ).request

        XCTAssertEqual(endpoint.historyExamples, [])
        XCTAssertFalse(endpoint.prompt.contains("Imperum"))
        XCTAssertEqual(local.historyExamples, examples)
        XCTAssertTrue(local.prompt.contains("Imperum"))
    }
}
