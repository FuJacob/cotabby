import Foundation
import XCTest
@testable import Cotabby

/// Locks how `LlamaSuggestionEngine` translates a `SuggestionRequest` into runtime calls: the
/// sampling options it hands the runtime, and when it drops the native prompt cache. The options
/// matter because the runtime validates cache reuse against their fingerprint; the resets matter
/// because dropping the cache on every superseded keystroke makes each one decode the whole prompt.
@MainActor
final class LlamaSuggestionEngineTests: XCTestCase {
    func test_generationOptions_mapRequestKnobsAndFieldShape() async throws {
        let runtime = FakeLlamaRuntime()
        let engine = LlamaSuggestionEngine(runtimeManager: runtime)

        _ = try await engine.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest(
            prefixText: "hel",
            prompt: "hel",
            trailingText: "lo there",
            maxPredictionTokens: 12,
            isMultiLineEnabled: false
        ))
        _ = try await engine.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest(
            prefixText: "Hello ",
            prompt: "Hello ",
            isMultiLineEnabled: true
        ))

        XCTAssertEqual(runtime.generateCalls.count, 2)
        let midWord = try XCTUnwrap(runtime.generateCalls.first?.options)
        XCTAssertEqual(midWord.maxPredictionTokens, 12)
        XCTAssertEqual(midWord.temperature, 0.1)
        XCTAssertEqual(midWord.topK, 20)
        XCTAssertEqual(midWord.topP, 0.7)
        XCTAssertEqual(midWord.minP, 0.08)
        XCTAssertEqual(midWord.repetitionPenalty, 1.05)
        XCTAssertEqual(midWord.seed, 42)
        XCTAssertTrue(midWord.singleLine, "Single-line fields must mask line-break tokens")
        XCTAssertTrue(midWord.forceWordContinuation, "A caret between letters must continue the word")

        let afterSpace = try XCTUnwrap(runtime.generateCalls.last?.options)
        XCTAssertFalse(afterSpace.singleLine)
        XCTAssertFalse(afterSpace.forceWordContinuation)
    }

    /// The prefill and the following generation must share one sampling fingerprint, otherwise
    /// the runtime rejects the warmed KV and the prewarm was wasted work.
    func test_prewarm_usesTheSameOptionsAsTheFollowingGeneration() async throws {
        let runtime = FakeLlamaRuntime()
        let engine = LlamaSuggestionEngine(runtimeManager: runtime)
        let request = CotabbyTestFixtures.suggestionRequest(prefixText: "Dear team", prompt: "Dear team")

        await engine.prewarm(for: request)
        _ = try await engine.generateSuggestion(for: request)

        XCTAssertEqual(runtime.prefillCalls.map(\.options), runtime.generateCalls.map(\.options))
        XCTAssertEqual(runtime.prefillCalls.count, 1)
    }

    func test_genuineRuntimeFailure_resetsThePromptCacheOnce() async throws {
        let runtime = FakeLlamaRuntime()
        let engine = LlamaSuggestionEngine(runtimeManager: runtime)
        let first = CotabbyTestFixtures.suggestionRequest(prefixText: "Hello", prompt: "Hello")
        let extended = CotabbyTestFixtures.suggestionRequest(prefixText: "Hello wo", prompt: "Hello wo")

        _ = try await engine.generateSuggestion(for: first)
        _ = try await engine.generateSuggestion(for: extended)

        runtime.generateResult = .failure(LlamaRuntimeError.generationFailed("decode failed"))
        _ = try? await engine.generateSuggestion(for: extended)
        runtime.generateResult = .success(.text(" ok"))
        _ = try await engine.generateSuggestion(for: extended)

        XCTAssertEqual(runtime.generateCalls.map(\.prompt), ["Hello", "Hello wo", "Hello wo", "Hello wo"])
        XCTAssertEqual(runtime.resetCount, 1)
    }

    /// A cancelled generation is not a runtime failure: the native prompt cache must survive it so
    /// the next keystroke reuses the shared prefix instead of decoding the whole prompt again.
    func test_cancelledGeneration_keepsThePromptCache() async throws {
        let runtime = FakeLlamaRuntime()
        let engine = LlamaSuggestionEngine(runtimeManager: runtime)
        let first = CotabbyTestFixtures.suggestionRequest(prefixText: "Hello", prompt: "Hello")
        let cancelled = CotabbyTestFixtures.suggestionRequest(prefixText: "Hello there", prompt: "Hello there")

        _ = try await engine.generateSuggestion(for: first)
        runtime.generateResult = .failure(LlamaRuntimeError.cancelled)
        _ = try? await engine.generateSuggestion(for: cancelled)
        runtime.generateResult = .success(.text(" ok"))
        _ = try await engine.generateSuggestion(for: cancelled)

        XCTAssertEqual(runtime.generateCalls.count, 3)
        XCTAssertEqual(runtime.resetCount, 0)
    }
}
