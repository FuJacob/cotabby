import Foundation
import Logging

#if canImport(FoundationModels)
import FoundationModels
#endif

/// File overview:
/// Adapts Apple's on-device Foundation Models framework to Tabby's existing
/// `SuggestionGenerating` capability. The coordinator should not care whether suggestions come
/// from llama.cpp or Apple Intelligence; that backend choice belongs in app composition.
///
/// This engine creates a fresh `LanguageModelSession` per request. That is the right default for
/// Tabby's autocomplete flow because each suggestion is a single-turn interaction and we do not
/// want prior model responses to accumulate in the context window.
///
/// The important behavioral nuance is that Foundation Models has a dedicated instructions channel.
/// We use that to tell the system model "this is inline autocomplete, not a chat reply," because a
/// bare text prefix like "hello" otherwise invites conversational continuations.
#if canImport(FoundationModels)
@available(macOS 26.0, *)
@MainActor
final class FoundationModelSuggestionEngine {
    private let availabilityService: FoundationModelAvailabilityService

    init(availabilityService: FoundationModelAvailabilityService) {
        self.availabilityService = availabilityService
    }

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        availabilityService.refresh()

        guard availabilityService.isAvailable else {
            TabbyLogger.suggestion.debug("Foundation model unavailable: \(self.availabilityService.userVisibleMessage)")
            throw SuggestionClientError.unavailable(availabilityService.userVisibleMessage)
        }

        do {
            TabbyLogger.suggestion.debug("Foundation model generating: prompt=\(request.prompt.count) bytes, max_tokens=\(request.maxPredictionTokens)")
            let startTime = Date()
            let prompt = FoundationModelPromptRenderer.prompt(for: request)
            // In production, `isAvailable == true` implies `systemLanguageModel` is non-nil because
            // only `SystemFoundationModelAvailabilityProvider` can report `.available`, and it owns
            // the model instance. If a future test provider reports available without a model, keep
            // the failure explicit instead of constructing a session with the wrong backend state.
            guard let model = availabilityService.systemLanguageModel else {
                throw SuggestionClientError.unavailable(
                    "Apple Intelligence reported available, but Tabby could not access the system language model."
                )
            }

            let session = LanguageModelSession(
                model: model,
                instructions: FoundationModelPromptRenderer.sessionInstructions(for: request)
            )
            let response = try await session.respond(
                to: prompt,
                options: generationOptions(for: request)
            )
            try Task.checkCancellation()

            let rawSuggestion = response.content
            let normalizedSuggestion = SuggestionTextNormalizer.normalize(
                rawSuggestion,
                for: request,
                promptEchoCandidates: [prompt]
            )

            let latency = Date().timeIntervalSince(startTime)
            TabbyLogger.suggestion.debug("Foundation model generated: raw=\(rawSuggestion.count) chars, normalized=\(normalizedSuggestion.count) chars, latency=\(Int(latency * 1000))ms")
            return SuggestionResult(
                generation: request.generation,
                rawText: rawSuggestion,
                text: normalizedSuggestion,
                latency: latency
            )
        } catch is CancellationError {
            TabbyLogger.suggestion.debug("Foundation model generation cancelled")
            throw SuggestionClientError.cancelled
        } catch let error as LanguageModelSession.GenerationError {
            TabbyLogger.suggestion.error("Foundation model generation error: \(error.localizedDescription)")
            throw mapGenerationError(error)
        } catch let error as SuggestionClientError {
            throw error
        } catch {
            TabbyLogger.suggestion.error("Foundation model unexpected error: \(error.localizedDescription)")
            throw SuggestionClientError.generationFailed(error.localizedDescription)
        }
    }

    /// Foundation Models sessions are already one-shot, so there is no backend context to clear.
    func resetCachedGenerationContext() async {}

    /// Maps Tabby's existing generation knobs onto the subset of Foundation Models options the
    /// system model exposes. We preserve the same upstream request shape so the coordinator does
    /// not fork behavior by backend.
    private func generationOptions(for request: SuggestionRequest) -> GenerationOptions {
        let sampling: GenerationOptions.SamplingMode

        if request.temperature <= 0.15 {
            sampling = .greedy
        } else {
            sampling = .random(top: max(request.topK, 1))
        }

        return GenerationOptions(
            sampling: sampling,
            temperature: request.temperature,
            maximumResponseTokens: max(request.maxPredictionTokens, 1)
        )
    }

    /// Converts framework-specific failures into Tabby's existing error vocabulary so the rest of
    /// the pipeline can stay backend-agnostic.
    private func mapGenerationError(
        _ error: LanguageModelSession.GenerationError
    ) -> SuggestionClientError {
        switch error {
        case .assetsUnavailable:
            return .unavailable("Apple Intelligence assets are unavailable right now.")
        case .unsupportedLanguageOrLocale:
            return .unsupportedLanguageOrLocale(
                "Apple Intelligence does not support the current language or locale for this request."
            )
        case .exceededContextWindowSize:
            return .generationFailed("The Apple on-device model rejected the prompt because it was too large.")
        case .guardrailViolation:
            return .generationFailed("Apple Intelligence rejected this request because of model guardrails.")
        case .unsupportedGuide:
            return .generationFailed("Apple Intelligence rejected a guided-generation request Tabby sent.")
        case .decodingFailure:
            return .generationFailed("Apple Intelligence returned a response Tabby could not decode.")
        case .rateLimited:
            return .generationFailed("Apple Intelligence is temporarily rate limited.")
        case .concurrentRequests:
            return .generationFailed("Apple Intelligence rejected a concurrent request for this session.")
        case .refusal:
            return .generationFailed("Apple Intelligence refused to answer this prompt.")
        @unknown default:
            return .generationFailed(error.localizedDescription)
        }
    }
}

@available(macOS 26.0, *)
extension FoundationModelSuggestionEngine: SuggestionGenerating {}
#endif
