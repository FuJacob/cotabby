import CoreGraphics
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
        let runtime = RecordingPrewarmRuntime()
        let engine = LlamaSuggestionEngine(runtimeManager: runtime)
        let request = makeRequest(prompt: "hello wor")

        await engine.prewarm(for: request)

        XCTAssertEqual(runtime.prefillPrompts, ["hello wor"])

        _ = try await engine.generateSuggestion(for: request)
        XCTAssertEqual(
            runtime.generateCachedPrefixBytes,
            ["hello wor".utf8.count],
            "A successful prefill should let the next identical-context request advertise full reuse."
        )
    }

    func test_failedPrewarm_leavesReuseHintCold() async throws {
        let runtime = RecordingPrewarmRuntime()
        runtime.prefillError = LlamaRuntimeError.unavailable("not loaded")
        let engine = LlamaSuggestionEngine(runtimeManager: runtime)
        let request = makeRequest(prompt: "hello wor")

        await engine.prewarm(for: request)

        _ = try await engine.generateSuggestion(for: request)
        XCTAssertEqual(
            runtime.generateCachedPrefixBytes,
            [nil],
            "A failed prefill must not advertise reuse the native cache cannot back."
        )
    }

    func test_resetClearsThePrimedHint() async throws {
        let runtime = RecordingPrewarmRuntime()
        let engine = LlamaSuggestionEngine(runtimeManager: runtime)
        let request = makeRequest(prompt: "hello wor")

        await engine.prewarm(for: request)
        await engine.resetCachedGenerationContext()

        _ = try await engine.generateSuggestion(for: request)
        XCTAssertEqual(runtime.generateCachedPrefixBytes, [nil])
    }

    // MARK: - Helpers

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

/// Records prefill calls and the reuse hints later generations advertise, so the prewarm contract
/// can be exercised without loading a real model.
@MainActor
private final class RecordingPrewarmRuntime: LlamaRuntimeGenerating {
    var prefillError: Error?
    var generateResult: Result<LlamaGenerationOutput, Error> = .success(.text("ok"))
    private(set) var prefillPrompts: [String] = []
    private(set) var generateCachedPrefixBytes: [Int?] = []

    func generate(
        prompt: String,
        cachedPrefixBytes: Int?,
        options: LlamaGenerationOptions
    ) async throws -> LlamaGenerationOutput {
        generateCachedPrefixBytes.append(cachedPrefixBytes)
        return try generateResult.get()
    }

    func resetPromptCache() {}

    func prefill(prompt: String, cachedPrefixBytes: Int?, options: LlamaGenerationOptions) async throws {
        if let prefillError {
            throw prefillError
        }
        prefillPrompts.append(prompt)
    }
}
