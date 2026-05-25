import Foundation

/// File overview:
/// Wraps the MLX runtime with prompt/result normalization for inline completion.
/// Mirrors `LlamaSuggestionEngine` — same prompt rendering, same text normalization,
/// different underlying runtime.
@MainActor
final class MLXSuggestionEngine {
    private let runtimeManager: MLXRuntimeManager

    init(runtimeManager: MLXRuntimeManager) {
        self.runtimeManager = runtimeManager
    }

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        do {
            let startTime = Date()
            let rawSuggestion = try await runtimeManager.generate(
                prompt: request.prompt,
                maxTokens: request.maxPredictionTokens,
                temperature: Float(request.temperature)
            )
            try Task.checkCancellation()

            let normalizedSuggestion = SuggestionTextNormalizer.normalize(
                rawSuggestion, for: request
            )
            return SuggestionResult(
                generation: request.generation,
                rawText: rawSuggestion,
                text: normalizedSuggestion,
                latency: Date().timeIntervalSince(startTime)
            )
        } catch is CancellationError {
            throw SuggestionClientError.cancelled
        } catch let error as LlamaRuntimeError {
            throw SuggestionClientError.unavailable(error.localizedDescription)
        } catch let error as SuggestionClientError {
            throw error
        } catch {
            throw SuggestionClientError.generationFailed(error.localizedDescription)
        }
    }

    func resetCachedGenerationContext() async {
        // MLX does not maintain a KV cache across requests currently.
    }
}

extension MLXSuggestionEngine: SuggestionGenerating {}
