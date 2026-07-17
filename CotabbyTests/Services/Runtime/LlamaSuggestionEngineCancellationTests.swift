import CoreGraphics
import Foundation
import XCTest
@testable import Cotabby

/// Regression tests for `LlamaSuggestionEngine`'s failure handling, guarding the input-lag fix:
/// a *cancelled* generation must be treated as a quiet cancellation, NOT as a runtime error that
/// wipes the native KV cache. During fast typing nearly every keystroke supersedes the in-flight
/// generation, so resetting the cache on each cancel (the base-model regression) fired ~twice a
/// second — synchronously destroying the prompt KV on the main actor and forcing a full prompt
/// re-decode on the next keystroke. These tests pin the routing for both cancellation shapes the
/// runtime can surface (`CancellationError` and `LlamaRuntimeError.cancelled`) and confirm genuine
/// runtime errors still reset.
@MainActor
final class LlamaSuggestionEngineCancellationTests: XCTestCase {

    func test_runtimeCancelledError_doesNotResetCache_andThrowsCancelled() async {
        // `LlamaRuntimeManager.generate` surfaces an outer-Task cancellation as
        // `LlamaRuntimeError.cancelled`. The engine must route that to the quiet cancel path.
        let runtime = FakeLlamaRuntime()
        runtime.generateResult = .failure(LlamaRuntimeError.cancelled)
        let engine = LlamaSuggestionEngine(runtimeManager: runtime)

        await assertThrowsCancelled(engine)
        XCTAssertEqual(runtime.resetCount, 0, "A cancelled generation must not reset the KV cache")
    }

    func test_pureCancellationError_doesNotResetCache_andThrowsCancelled() async {
        // Guards the pre-existing clean path so a future refactor cannot regress it either.
        let runtime = FakeLlamaRuntime()
        runtime.generateResult = .failure(CancellationError())
        let engine = LlamaSuggestionEngine(runtimeManager: runtime)

        await assertThrowsCancelled(engine)
        XCTAssertEqual(runtime.resetCount, 0)
    }

    func test_genuineRuntimeError_resetsCache_andThrowsUnavailable() async {
        let runtime = FakeLlamaRuntime()
        runtime.generateResult = .failure(LlamaRuntimeError.generationFailed("boom"))
        let engine = LlamaSuggestionEngine(runtimeManager: runtime)

        do {
            _ = try await engine.generateSuggestion(for: makeRequest(prompt: "hello"))
            XCTFail("Expected a thrown error")
        } catch SuggestionClientError.unavailable {
            // Expected: a real runtime failure does reset and surfaces as unavailable.
        } catch {
            XCTFail("Expected SuggestionClientError.unavailable, got \(error)")
        }
        XCTAssertEqual(runtime.resetCount, 1, "A genuine runtime error should reset the KV cache exactly once")
    }

    func test_successfulGeneration_doesNotResetCache() async throws {
        let runtime = FakeLlamaRuntime()
        runtime.generateResult = .success(.text("world"))
        let engine = LlamaSuggestionEngine(runtimeManager: runtime)

        let result = try await engine.generateSuggestion(for: makeRequest(prompt: "hello "))

        XCTAssertEqual(result.generation, 1)
        XCTAssertEqual(runtime.resetCount, 0)
    }

    func test_lowConfidenceSuppression_isAttributedAsLowConfidence() async throws {
        let runtime = FakeLlamaRuntime()
        runtime.generateResult = .success(
            LlamaGenerationOutput(text: "", averageLogprob: -5.2, suppressedByLowConfidence: true)
        )
        let engine = LlamaSuggestionEngine(runtimeManager: runtime)

        let result = try await engine.generateSuggestion(for: makeRequest(prompt: "hello "))

        XCTAssertEqual(result.text, "")
        XCTAssertEqual(
            result.suppressionReason,
            CompletionSuppressionReason.lowConfidence.rawValue,
            "a runtime-withheld completion must not read as 'the model produced nothing'"
        )
        XCTAssertEqual(runtime.resetCount, 0)
    }

    func test_suggestionClientError_resetsCache_andRethrowsSameError() async {
        // A `SuggestionClientError` crossing the runtime boundary is a genuine failure, so it must
        // reset the cache but keep its original case and message for the coordinator's diagnostics.
        let runtime = FakeLlamaRuntime()
        runtime.generateResult = .failure(SuggestionClientError.unavailable("model not loaded"))
        let engine = LlamaSuggestionEngine(runtimeManager: runtime)

        do {
            _ = try await engine.generateSuggestion(for: makeRequest(prompt: "hello"))
            XCTFail("Expected a thrown error")
        } catch SuggestionClientError.unavailable(let message) {
            XCTAssertEqual(message, "model not loaded")
        } catch {
            XCTFail("Expected SuggestionClientError.unavailable to pass through unchanged, got \(error)")
        }
        XCTAssertEqual(runtime.resetCount, 1, "A client error should reset the KV cache exactly once")
    }

    func test_unexpectedError_resetsCache_andWrapsAsGenerationFailed() async {
        // Errors outside the engine's known vocabulary fall into the catch-all: reset the cache and
        // surface a `generationFailed` carrying the underlying description.
        let runtime = FakeLlamaRuntime()
        runtime.generateResult = .failure(UnexpectedRuntimeBoom())
        let engine = LlamaSuggestionEngine(runtimeManager: runtime)

        do {
            _ = try await engine.generateSuggestion(for: makeRequest(prompt: "hello"))
            XCTFail("Expected a thrown error")
        } catch SuggestionClientError.generationFailed(let message) {
            XCTAssertEqual(message, "UNEXPECTED_BOOM")
        } catch {
            XCTFail("Expected SuggestionClientError.generationFailed, got \(error)")
        }
        XCTAssertEqual(runtime.resetCount, 1, "An unexpected error should reset the KV cache exactly once")
    }

    // MARK: - Helpers

    private func assertThrowsCancelled(
        _ engine: LlamaSuggestionEngine,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await engine.generateSuggestion(for: makeRequest(prompt: "hello"))
            XCTFail("Expected a thrown error", file: file, line: line)
        } catch SuggestionClientError.cancelled {
            // Expected quiet cancellation.
        } catch {
            XCTFail("Expected SuggestionClientError.cancelled, got \(error)", file: file, line: line)
        }
    }

    private func makeRequest(prompt: String) -> SuggestionRequest {
        let snapshot = FocusedInputSnapshot(
            applicationName: "TestApp",
            bundleIdentifier: "com.example.TestApp",
            processIdentifier: 123,
            elementIdentifier: "field",
            role: "AXTextField",
            subrole: nil,
            caretRect: .zero,
            inputFrameRect: nil,
            caretSource: "test",
            caretQuality: .exact,
            observedCharWidth: nil,
            precedingText: prompt,
            trailingText: "",
            selection: NSRange(location: prompt.count, length: 0),
            isSecure: false
        )
        let context = FocusedInputContext(snapshot: snapshot, generation: 1)

        return SuggestionRequest(
            context: context,
            prefixText: prompt,
            prompt: prompt,
            generation: context.generation,
            maxPredictionTokens: 8,
            temperature: 0.1,
            topK: 20,
            topP: 0.7,
            minP: 0.08,
            repetitionPenalty: 1.05,
            randomSeed: 42,
            maxSuffixCharacters: 192,
            completionLengthInstruction: "Return only the next few words.",
            userName: nil,
            customRules: [],
            languageInstruction: nil,
            clipboardContext: nil,
            visualContextSummary: nil,
            isMultiLineEnabled: false
        )
    }
}

/// An error type the engine has no dedicated handling for, used to drive the catch-all wrap path.
private struct UnexpectedRuntimeBoom: LocalizedError {
    var errorDescription: String? { "UNEXPECTED_BOOM" }
}

/// Minimal `LlamaRuntimeGenerating` fake that returns a staged result and counts cache resets,
/// so the engine's failure routing can be exercised without loading a real model.
@MainActor
private final class FakeLlamaRuntime: LlamaRuntimeGenerating {
    var generateResult: Result<LlamaGenerationOutput, Error> = .success(.text(""))
    private(set) var resetCount = 0

    func generate(
        prompt: String,
        cachedPrefixBytes: Int?,
        options: LlamaGenerationOptions
    ) async throws -> LlamaGenerationOutput {
        try generateResult.get()
    }

    func resetPromptCache() {
        resetCount += 1
    }
}
