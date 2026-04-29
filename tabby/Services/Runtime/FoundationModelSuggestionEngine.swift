import Foundation
import FoundationModels

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
@MainActor
final class FoundationModelSuggestionEngine {
    private let availabilityService: FoundationModelAvailabilityService

    init(availabilityService: FoundationModelAvailabilityService) {
        self.availabilityService = availabilityService
    }

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        availabilityService.refresh()

        guard availabilityService.isAvailable else {
            throw SuggestionClientError.unavailable(availabilityService.userVisibleMessage)
        }

        do {
            let startTime = Date()
            let session = LanguageModelSession(
                model: availabilityService.model,
                instructions: FoundationModelPromptRenderer.sessionInstructions(for: request)
            )
            let response = try await session.respond(
                to: FoundationModelPromptRenderer.prompt(for: request),
                options: generationOptions(for: request)
            )
            try Task.checkCancellation()

            let rawSuggestion = response.content
            let normalizedSuggestion = SuggestionTextNormalizer.normalize(
                rawSuggestion,
                for: request
            )

            return SuggestionResult(
                generation: request.generation,
                rawText: rawSuggestion,
                text: normalizedSuggestion,
                latency: Date().timeIntervalSince(startTime)
            )
        } catch is CancellationError {
            throw SuggestionClientError.cancelled
        } catch let error as LanguageModelSession.GenerationError {
            throw mapGenerationError(error)
        } catch let error as SuggestionClientError {
            throw error
        } catch {
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
            return .unavailable("Apple Intelligence does not support the current language or locale.")
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

extension FoundationModelSuggestionEngine: SuggestionGenerating {}
