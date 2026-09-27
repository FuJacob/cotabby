import Foundation
import XCTest
@testable import Cotabby

/// Tests for the llama engine's streaming contract: cumulative raw partials from the runtime are
/// normalized and forwarded to `onPartial` on the main actor, and the final result still goes
/// through the existing single-shot path (tracker recording, normalization, latency).
@MainActor
final class LlamaSuggestionEngineStreamingTests: XCTestCase {

    func test_streamingGeneration_forwardsNormalizedCumulativePartials() async throws {
        let runtime = StreamingFakeRuntime()
        // The empty first partial normalizes to nothing and must be withheld, not forwarded.
        runtime.partialRawTexts = ["", " wor", " world ag"]
        runtime.finalText = " world again"
        let engine = LlamaSuggestionEngine(runtimeManager: runtime)

        var partials: [SuggestionResult] = []
        let result = try await engine.generateSuggestion(for: makeRequest(prompt: "Hello")) { partial in
            partials.append(partial)
        }

        // Partials hop to the main actor as tasks; drain before asserting.
        try await drainUntil { partials.count >= 2 }

        XCTAssertEqual(result.rawText, " world again")
        XCTAssertEqual(partials.map(\.rawText), [" wor", " world ag"])
        XCTAssertEqual(partials.map(\.generation), [1, 1], "Partials must carry the request generation for stale guards.")
    }

    func test_plainGeneration_neverInvokesPartialHook() async throws {
        let runtime = StreamingFakeRuntime()
        runtime.partialRawTexts = [" wor"]
        runtime.finalText = " world"
        let engine = LlamaSuggestionEngine(runtimeManager: runtime)

        _ = try await engine.generateSuggestion(for: makeRequest(prompt: "Hello"))

        XCTAssertEqual(runtime.streamingCallCount, 0, "The single-shot entry point must use the non-streaming runtime path.")
    }

    // MARK: - Helpers

    /// Pumps the main actor until `condition` holds or a bounded number of yields elapse, so the
    /// forwarded-partial tasks get a chance to run without arbitrary sleeps.
    private func drainUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func makeRequest(prompt: String) -> SuggestionRequest {
        CotabbyTestFixtures.suggestionRequest(prefixText: prompt, prompt: prompt)
    }
}

/// Runtime fake that emits staged cumulative raw partials through the streaming entry point and
/// counts which entry point was used.
@MainActor
private final class StreamingFakeRuntime: LlamaRuntimeGenerating {
    var partialRawTexts: [String] = []
    var finalText = ""
    private(set) var streamingCallCount = 0

    func generate(
        prompt: String,
        cachedPrefixBytes: Int?,
        options: LlamaGenerationOptions
    ) async throws -> LlamaGenerationOutput {
        .text(finalText)
    }

    func generate(
        prompt: String,
        cachedPrefixBytes: Int?,
        options: LlamaGenerationOptions,
        onPartialRawText: (@Sendable (String) -> Void)?
    ) async throws -> LlamaGenerationOutput {
        streamingCallCount += 1
        for partial in partialRawTexts {
            onPartialRawText?(partial)
        }
        return .text(finalText)
    }

    func resetPromptCache() {}
}
