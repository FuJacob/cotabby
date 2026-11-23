import XCTest
@testable import Cotabby

/// How the user's earlier writing reaches each prompt: quoted ahead of the caret text in the base
/// prompt, carried per request (never in the cached instructions) on Apple Intelligence, and never
/// sent to the user's own endpoint. The phrase engine that reads the same history has its own suite.
final class TypingHistoryPromptTests: XCTestCase {
    func test_basePromptQuotesExamplesBeforeTheCaretText() {
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: "The POC is",
            userName: nil,
            historyExamples: ["The Imperum POC starts Monday."]
        )

        XCTAssertTrue(prompt.contains("Earlier writing by the same author:\n“The Imperum POC starts Monday.”"))
        XCTAssertTrue(prompt.hasSuffix("The POC is"), "The caret text must stay last")
    }

    func test_historySectionIsDroppedWholeRatherThanCutMidQuote() {
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: String(repeating: "word ", count: 30),
            userName: nil,
            historyExamples: [String(repeating: "earlier ", count: 40)],
            contextBudget: 200
        )

        XCTAssertFalse(prompt.contains("“"), "A partly kept history section would leave an unclosed quote")
    }

    func test_basePromptWithoutExamplesIsUnchanged() {
        XCTAssertEqual(
            BaseCompletionPromptRenderer.prompt(prefixText: "The POC is", userName: nil),
            BaseCompletionPromptRenderer.prompt(
                prefixText: "The POC is", userName: nil, historyExamples: []
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
