import XCTest
@testable import Cotabby

@MainActor
final class TypingHistoryPhraseEngineTests: XCTestCase {

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
        let base = TestLifetime.retain(CountingEngine())
        let history = TestLifetime.retain(FixedHistory())
        history.phrase = phrase
        let wrapper = TestLifetime.retain(
            TypingHistoryPhraseEngine(wrapping: base, history: history, engineKind: { engine })
        )
        return (wrapper, base, history)
    }

    func test_confidentPhraseAnswersWithoutCallingTheModel() async throws {
        let (engine, base, _) = makeEngine(phrase: " Robin")

        let result = try await engine.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())

        XCTAssertEqual(result.text, " Robin")
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
