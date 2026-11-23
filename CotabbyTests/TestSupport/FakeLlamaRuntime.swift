import Foundation
@testable import Cotabby

/// Stand-in for `LlamaRuntimeManager` so `LlamaSuggestionEngine` can be driven without loading a
/// model. It returns a staged result and records every call, because the engine's contracts are
/// about what it asks of the runtime (sampling options, reuse hints, prefills, cache resets) as
/// much as what it returns.
@MainActor
final class FakeLlamaRuntime: LlamaRuntimeGenerating {
    struct Call: Equatable {
        let prompt: String
        let cachedPrefixBytes: Int?
        let options: LlamaGenerationOptions
    }

    var generateResult: Result<LlamaGenerationOutput, Error> = .success(.text(" ok"))
    /// Cumulative raw partials handed to the streaming hook before the staged result is returned.
    var partialRawTexts: [String] = []
    var prefillError: Error?

    private(set) var generateCalls: [Call] = []
    /// Counts only the streaming entry point, so a test can tell which one the engine chose.
    private(set) var streamingCallCount = 0
    /// Successful prefills only: a throwing prefill decoded nothing the engine may reuse.
    private(set) var prefillCalls: [Call] = []
    private(set) var resetCount = 0

    func generate(
        prompt: String,
        cachedPrefixBytes: Int?,
        options: LlamaGenerationOptions
    ) async throws -> LlamaGenerationOutput {
        generateCalls.append(Call(prompt: prompt, cachedPrefixBytes: cachedPrefixBytes, options: options))
        return try generateResult.get()
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
        return try await generate(prompt: prompt, cachedPrefixBytes: cachedPrefixBytes, options: options)
    }

    func resetPromptCache() {
        resetCount += 1
    }

    func prefill(prompt: String, cachedPrefixBytes: Int?, options: LlamaGenerationOptions) async throws {
        if let prefillError {
            throw prefillError
        }
        prefillCalls.append(Call(prompt: prompt, cachedPrefixBytes: cachedPrefixBytes, options: options))
    }
}
