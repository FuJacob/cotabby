import Foundation
@testable import Cotabby

/// Stand-in for `LlamaRuntimeManager` so `LlamaSuggestionEngine` can be driven without loading a
/// model. It returns a staged result and records every call, because the engine's contracts are
/// about what it asks of the runtime (sampling options, prefills, cache resets) as much as what it
/// returns.
@MainActor
final class FakeLlamaRuntime: LlamaRuntimeGenerating {
    struct Call: Equatable {
        let prompt: String
        let options: LlamaGenerationOptions
    }

    var generateResult: Result<LlamaGenerationOutput, Error> = .success(.text(" ok"))
    /// Cumulative raw partials handed to the streaming hook before the staged result is returned.
    var partialRawTexts: [String] = []
    var prefillError: Error?

    private(set) var generateCalls: [Call] = []
    /// Generations that asked for partials, so a test can tell whether the engine wanted them.
    private(set) var partialHookCallCount = 0
    /// Successful prefills only: a throwing prefill decoded nothing the engine may reuse.
    private(set) var prefillCalls: [Call] = []
    private(set) var resetCount = 0

    func generate(
        prompt: String,
        options: LlamaGenerationOptions,
        onPartialRawText: (@Sendable (String) -> Void)?
    ) async throws -> LlamaGenerationOutput {
        generateCalls.append(Call(prompt: prompt, options: options))
        if let onPartialRawText {
            partialHookCallCount += 1
            for partial in partialRawTexts {
                onPartialRawText(partial)
            }
        }
        return try generateResult.get()
    }

    func resetPromptCache() {
        resetCount += 1
    }

    func prefill(prompt: String, options: LlamaGenerationOptions) async throws {
        if let prefillError {
            throw prefillError
        }
        prefillCalls.append(Call(prompt: prompt, options: options))
    }
}
