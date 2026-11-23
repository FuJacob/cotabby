import Foundation
import XCTest
@testable import Cotabby

/// Tests for the llama half of prewarm-on-focus. A focus change destroys the native sequence, so
/// without a prefill the first suggestion in every field pays the full cold prompt decode. These
/// pin the contract: prewarm prefills through the runtime, and a failed prefill is swallowed.
@MainActor
final class LlamaSuggestionEnginePrewarmTests: XCTestCase {

    func test_prewarm_prefillsTheFocusedFieldsPrompt() async {
        let runtime = FakeLlamaRuntime()
        let engine = LlamaSuggestionEngine(runtimeManager: runtime)

        await engine.prewarm(for: makeRequest(prompt: "hello wor"))

        XCTAssertEqual(runtime.prefillCalls.map(\.prompt), ["hello wor"])
    }

    func test_failedPrewarm_isSwallowedAndTheNextGenerationStillRuns() async throws {
        let runtime = FakeLlamaRuntime()
        runtime.prefillError = LlamaRuntimeError.unavailable("not loaded")
        let engine = LlamaSuggestionEngine(runtimeManager: runtime)
        let request = makeRequest(prompt: "hello wor")

        await engine.prewarm(for: request)
        let result = try await engine.generateSuggestion(for: request)

        XCTAssertEqual(runtime.prefillCalls, [])
        XCTAssertEqual(runtime.generateCalls.map(\.prompt), ["hello wor"])
        XCTAssertEqual(result.rawText, " ok")
        XCTAssertEqual(runtime.resetCount, 0, "A missed warmup is not a runtime failure and must not drop the cache")
    }

    // MARK: - Helpers

    private func makeRequest(prompt: String) -> SuggestionRequest {
        CotabbyTestFixtures.suggestionRequest(prefixText: prompt, prompt: prompt)
    }
}
