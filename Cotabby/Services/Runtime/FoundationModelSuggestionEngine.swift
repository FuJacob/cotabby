import Foundation
import Logging

#if canImport(FoundationModels)
import FoundationModels
#endif

/// File overview:
/// Adapts Apple's on-device Foundation Models framework to Cotabby's existing
/// `SuggestionGenerating` capability. The coordinator should not care whether suggestions come
/// from llama.cpp or Apple Intelligence; that backend choice belongs in app composition.
///
/// The engine caches a pristine `LanguageModelSession` so the focus-time `prewarm(for:)` call can
/// hand the same prewarmed session to the first user-typed request. Reuse is bounded: once a
/// session has actually serviced a `respond` (its transcript has grown past the pristine count)
/// or is mid-stream (`isResponding == true`), the next request builds a fresh session instead.
/// This keeps the prewarm latency win on the first keystroke after focus without inheriting
/// Apple's two single-flight failure modes — `concurrentRequests` from overlapping streams on the
/// same session, and `exceededContextWindowSize` from transcript entries piling up over many
/// keystrokes in the same field. See `ensureSession` for the reuse predicate.
///
/// `prewarm(for:)` is the supported hook for "the user just focused an editable field; a real
/// request is likely within a second." The coordinator calls it from the focus path; the engine
/// builds (or reuses) the session and calls Apple's `LanguageModelSession.prewarm()` so weight
/// loading and instruction tokenization happen before the first user-visible respond call.
///
/// Generation itself goes through `session.streamResponse` rather than `session.respond`. Apple's
/// stream yields cumulative partials, so the loop captures the latest snapshot and exits with it
/// as the final raw text. The win is responsiveness to cancellation: `Task.checkCancellation()`
/// inside the loop lets the coordinator interrupt mid-decode when the user types past the
/// in-flight suggestion, where `respond` would otherwise have to run to completion. The external
/// `SuggestionResult` shape is unchanged, so the rest of the pipeline (overlay, presenter,
/// active-session reconciliation) stays as-is — pushing partials all the way to the overlay is a
/// separate, larger change scoped to a follow-up.
#if canImport(FoundationModels)
@available(macOS 26.0, *)
@MainActor
final class FoundationModelSuggestionEngine {
    private let availabilityService: FoundationModelAvailabilityService
    private var cachedSession: CachedSession?

    init(availabilityService: FoundationModelAvailabilityService) {
        self.availabilityService = availabilityService
    }

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        availabilityService.refresh()

        let baseMetadata: Logger.Metadata = [
            "request_id": .string(request.requestID),
            "engine": .string("apple_intelligence")
        ]

        guard availabilityService.isAvailable else {
            let message = availabilityService.userVisibleMessage
            CotabbyLogger.suggestion.debug(
                "Foundation model unavailable: \(message)",
                metadata: baseMetadata
            )
            throw SuggestionClientError.unavailable(message)
        }

        do {
            let promptBytes = request.prompt.count
            let maxTokens = request.maxPredictionTokens
            CotabbyLogger.suggestion.debug(
                "Foundation model generating",
                metadata: baseMetadata.merging([
                    "prompt_bytes": .stringConvertible(promptBytes),
                    "max_tokens": .stringConvertible(maxTokens)
                ]) { _, new in new }
            )
            let startTime = Date()
            let prompt = FoundationModelPromptRenderer.prompt(for: request)
            // In production, `isAvailable == true` implies `systemLanguageModel` is non-nil because
            // only `SystemAvailabilityProvider` can report `.available`, and it owns
            // the model instance. If a future test provider reports available without a model, keep
            // the failure explicit instead of constructing a session with the wrong backend state.
            guard let model = availabilityService.systemLanguageModel else {
                throw SuggestionClientError.unavailable(
                    "Apple Intelligence reported available, but Cotabby could not access the system language model."
                )
            }

            let session = ensureSession(for: request, model: model)
            let stream = session.streamResponse(
                to: prompt,
                options: generationOptions(for: request)
            )
            // Apple's stream yields cumulative `Snapshot` values whose `.content` carries the
            // text generated so far. Capture each snapshot first and check cancellation after, so a
            // late cancel between the final snapshot and its assignment doesn't discard fully
            // decoded text — cancellation always throws, but keeping the best-available text saved
            // before honoring the signal makes the intent obvious.
            var rawSuggestion = ""
            var didReceiveSnapshot = false
            for try await partial in stream {
                rawSuggestion = partial.content
                didReceiveSnapshot = true
                try Task.checkCancellation()
            }
            try Task.checkCancellation()
            // Apple's documented contract is at least one snapshot on a successful stream, so a
            // zero-snapshot path is treated as a generation failure rather than a silent empty
            // suggestion — the latter would let the overlay clear without surfacing that the model
            // produced literally nothing.
            guard didReceiveSnapshot else {
                throw SuggestionClientError.generationFailed(
                    "Apple Intelligence finished streaming without producing any content."
                )
            }
            let normalizedSuggestion = SuggestionTextNormalizer.normalize(
                rawSuggestion,
                for: request,
                promptEchoCandidates: [prompt]
            )

            let latency = Date().timeIntervalSince(startTime)
            let rawChars = rawSuggestion.count
            let normalizedChars = normalizedSuggestion.count
            let latencyMs = Int(latency * 1000)
            CotabbyLogger.suggestion.debug(
                "Foundation model generated",
                metadata: baseMetadata.merging([
                    "raw_chars": .stringConvertible(rawChars),
                    "normalized_chars": .stringConvertible(normalizedChars),
                    "latency_ms": .stringConvertible(latencyMs)
                ]) { _, new in new }
            )
            CotabbyLogger.llmIO.debug(
                "foundation_model generation",
                metadata: baseMetadata.merging([
                    "prompt": .string(prompt),
                    "completion_raw": .string(rawSuggestion),
                    "completion_normalized": .string(normalizedSuggestion),
                    "prompt_bytes": .stringConvertible(prompt.utf8.count),
                    "raw_chars": .stringConvertible(rawChars),
                    "normalized_chars": .stringConvertible(normalizedChars),
                    "latency_ms": .stringConvertible(latencyMs),
                    "max_tokens": .stringConvertible(request.maxPredictionTokens)
                ]) { _, new in new }
            )
            return SuggestionResult(
                generation: request.generation,
                rawText: rawSuggestion,
                text: normalizedSuggestion,
                latency: latency
            )
        } catch is CancellationError {
            CotabbyLogger.suggestion.debug("Foundation model generation cancelled", metadata: baseMetadata)
            throw SuggestionClientError.cancelled
        } catch let error as LanguageModelSession.GenerationError {
            CotabbyLogger.suggestion.error(
                "Foundation model generation error: \(error.localizedDescription)",
                metadata: baseMetadata
            )
            throw mapGenerationError(error)
        } catch let error as SuggestionClientError {
            throw error
        } catch {
            CotabbyLogger.suggestion.error(
                "Foundation model unexpected error: \(error.localizedDescription)",
                metadata: baseMetadata
            )
            throw SuggestionClientError.generationFailed(error.localizedDescription)
        }
    }

    /// Best-effort warmup. Apple's prewarm loads weights into memory and primes the instruction
    /// prefix cache. We swallow errors because prewarming is opportunistic — the next
    /// `respond` call will surface real availability or generation failures with the right
    /// vocabulary, and reporting them here would just produce noise.
    func prewarm(for request: SuggestionRequest) async {
        availabilityService.refresh()
        guard availabilityService.isAvailable else {
            return
        }
        guard let model = availabilityService.systemLanguageModel else {
            return
        }

        let session = ensureSession(for: request, model: model)
        session.prewarm()
        CotabbyLogger.suggestion.debug("Foundation model session prewarmed")
    }

    /// Dropping the cached session forces the next request to rebuild instructions, which is the
    /// right behavior when the coordinator signals the editing context is no longer continuous
    /// (focus changes, settings edits). Apple's session also holds a transcript that we
    /// deliberately do not want to leak across editing contexts.
    func resetCachedGenerationContext() async {
        cachedSession = nil
    }

    /// Returns the cached session when it is safe to reuse, otherwise builds a fresh session
    /// and replaces the cache. The cache key (rendered instructions) keeps this correct if the
    /// renderer composition rules change later.
    ///
    /// Reuse is gated on three conditions that together avoid two Apple-surfaced failures the
    /// previous unconditional-reuse design was vulnerable to:
    ///
    /// - `cached.instructions == instructions`: the cached session was built with this exact
    ///   instruction string. Any settings edit (custom rules, language override) that re-renders
    ///   instructions forces a rebuild.
    /// - `!cached.session.isResponding`: Apple's `LanguageModelSession` rejects a second concurrent
    ///   `respond` / `streamResponse` with `.concurrentRequests`. Swift task cancellation is
    ///   cooperative, so the coordinator's `cancelPredictionWork()` + `schedulePrediction()` pair
    ///   can leave the previous stream still draining inside Apple's runtime when the next request
    ///   arrives. Falling through to a fresh session keeps that case from surfacing as a
    ///   user-visible `generationFailed` error.
    /// - `cached.session.transcript.count == cached.pristineTranscriptCount`: a successful (or even
    ///   cancelled) `respond` appends the prompt and response to the session's transcript. Reusing
    ///   the session indefinitely accumulates entries that all replay through the 4096-token
    ///   shared context, which Apple eventually surfaces as `.exceededContextWindowSize`. Bounded
    ///   reuse keeps the prewarm benefit on the first keystroke after focus — the session is
    ///   built and prewarmed on focus change, then consumed once — and any further keystroke in
    ///   the same field starts from a fresh session, matching the pre-PR single-turn behavior.
    ///
    /// The cache key intentionally omits `model` identity. `availabilityService` owns the singleton
    /// `SystemLanguageModel` and only swaps it on app restart, never mid-session — so a cached
    /// session can never be silently bound to a stale model. If that invariant ever changes
    /// (e.g. live Apple Intelligence asset reloads), include `ObjectIdentifier(model)` here.
    private func ensureSession(
        for request: SuggestionRequest,
        model: SystemLanguageModel
    ) -> LanguageModelSession {
        let instructions = FoundationModelPromptRenderer.sessionInstructions(for: request)
        if let cached = cachedSession,
           cached.instructions == instructions,
           !cached.session.isResponding,
           cached.session.transcript.count == cached.pristineTranscriptCount {
            return cached.session
        }

        let session = LanguageModelSession(model: model, instructions: instructions)
        cachedSession = CachedSession(
            instructions: instructions,
            session: session,
            pristineTranscriptCount: session.transcript.count
        )
        return session
    }

    /// Maps Cotabby's existing generation knobs onto the subset of Foundation Models options the
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

    /// Converts framework-specific failures into Cotabby's existing error vocabulary so the rest of
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
            return .generationFailed("Apple Intelligence rejected a guided-generation request Cotabby sent.")
        case .decodingFailure:
            return .generationFailed("Apple Intelligence returned a response Cotabby could not decode.")
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

    private struct CachedSession {
        let instructions: String
        let session: LanguageModelSession
        /// Snapshot of `session.transcript.count` immediately after construction (and after any
        /// `prewarm()`, which does not modify the transcript). A respond call appends entries,
        /// so a count divergence is the cue that this session is no longer single-turn safe.
        let pristineTranscriptCount: Int
    }
}

@available(macOS 26.0, *)
extension FoundationModelSuggestionEngine: SuggestionGenerating {}
#endif
