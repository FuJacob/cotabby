import Foundation
import XCTest
@testable import Cotabby

/// Tests for the llama half of prewarm-on-focus: a focus change used to leave the llama engine's
/// `prewarm` as the protocol no-op while the focus reset destroyed the native sequence, so the
/// first suggestion in every field paid the full cold prompt decode. These pin the new contract:
/// prewarm prefills through the runtime and primes the reuse hint only when the prefill succeeded.
@MainActor
final class LlamaSuggestionEnginePrewarmTests: XCTestCase {

    func test_prewarm_prefillsAndPrimesTheReuseHint() async throws {
        let runtime = FakeLlamaRuntime()
        let engine = LlamaSuggestionEngine(runtimeManager: runtime)
        let request = makeRequest(prompt: "hello wor")

        await engine.prewarm(for: request)

        XCTAssertEqual(runtime.prefillCalls.map(\.prompt), ["hello wor"])

        _ = try await engine.generateSuggestion(for: request)
        XCTAssertEqual(
            runtime.generateCalls.map(\.cachedPrefixBytes),
            ["hello wor".utf8.count],
            "A successful prefill should let the next identical-context request advertise full reuse."
        )
    }

    func test_failedPrewarm_leavesReuseHintCold() async throws {
        let runtime = FakeLlamaRuntime()
        runtime.prefillError = LlamaRuntimeError.unavailable("not loaded")
        let engine = LlamaSuggestionEngine(runtimeManager: runtime)
        let request = makeRequest(prompt: "hello wor")

        await engine.prewarm(for: request)

        _ = try await engine.generateSuggestion(for: request)
        XCTAssertEqual(
            runtime.generateCalls.map(\.cachedPrefixBytes),
            [nil],
            "A failed prefill must not advertise reuse the native cache cannot back."
        )
    }

    func test_resetClearsThePrimedHint() async throws {
        let runtime = FakeLlamaRuntime()
        let engine = LlamaSuggestionEngine(runtimeManager: runtime)
        let request = makeRequest(prompt: "hello wor")

        await engine.prewarm(for: request)
        await engine.resetCachedGenerationContext()

        _ = try await engine.generateSuggestion(for: request)
        XCTAssertEqual(runtime.generateCalls.map(\.cachedPrefixBytes), [nil])
    }

    // MARK: - Helpers

    private func makeRequest(prompt: String) -> SuggestionRequest {
        CotabbyTestFixtures.suggestionRequest(prefixText: prompt, prompt: prompt)
    }
}
