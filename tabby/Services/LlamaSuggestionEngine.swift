import Foundation

/// File overview:
/// Wraps the raw llama runtime with prompt/result normalization that is specific to inline
/// completion. This is where raw generated text becomes a short suggestion Tabby can safely show.
///
/// Keeps prompt normalization separate from the raw llama runtime.
/// That separation matters because prompt strategy changes far more often than model lifecycle code.
@MainActor
final class LlamaSuggestionEngine {
    private let runtimeManager: LlamaRuntimeManager

    init(runtimeManager: LlamaRuntimeManager) {
        self.runtimeManager = runtimeManager
    }

    /// Executes one generation request and packages the raw and normalized result for the coordinator.
    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        do {
            let startTime = Date()
            let rawSuggestion = try await runtimeManager.generate(
                prompt: request.prompt,
                maxPredictionTokens: request.maxPredictionTokens,
                temperature: request.temperature,
                topK: request.topK,
                topP: request.topP,
                minP: request.minP,
                repetitionPenalty: request.repetitionPenalty
            )
            try Task.checkCancellation()

            let normalizedSuggestion = normalizeSuggestion(rawSuggestion, for: request)
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

    /// Normalizes raw model output into a short inline completion by stripping control noise,
    /// removing echoes, and limiting the result to the first line.
    private func normalizeSuggestion(_ rawSuggestion: String, for request: SuggestionRequest) -> String {
        var normalized = rawSuggestion.replacingOccurrences(of: "\r", with: "")

        if !request.prompt.isEmpty, normalized.hasPrefix(request.prompt) {
            normalized.removeFirst(request.prompt.count)
        }

        if let firstLine = normalized.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first {
            normalized = String(firstLine)
        }
        
        let structuralTags = [
            "<|im_end|>", 
            "<|im_start|>"
        ]
        
        for tag in structuralTags {
            if let tagRange = normalized.range(of: tag) {
                normalized = String(normalized[..<tagRange.lowerBound])
            }
        }

        normalized = normalized.trimmingCharacters(in: .controlCharacters.union(.newlines))

        if normalized.hasPrefix(request.context.trailingText), !request.context.trailingText.isEmpty {
            return ""
        }

        if normalized.count > 120 {
            normalized = String(normalized.prefix(120))
        }

        return normalized.trimmingCharacters(in: .newlines)
    }
}
