import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Wraps the raw llama runtime with prompt/result normalization that is specific to inline
/// completion. This is where raw generated text becomes a short suggestion Ghostype can safely show.
///
/// Keeps prompt normalization separate from the raw llama runtime.
/// That separation matters because prompt strategy changes far more often than model lifecycle code.
@MainActor
final class LlamaSuggestionEngine {
    private let runtimeManager: LlamaRuntimeGenerating
    /// The focus-time warmup in flight, if any. A real generation cancels it on entry so it never
    /// queues behind a warmup for a prompt the user has already typed past.
    private var inflightPrewarmTask: Task<Void, Never>?

    init(runtimeManager: LlamaRuntimeGenerating) {
        self.runtimeManager = runtimeManager
    }

    /// Shipped confidence floor (mean per-token log-probability). -infinity disables the gate AND
    /// the per-token logprob computation behind it; any other value turns both on.
    ///
    /// Shipped OFF. A floor of -1.5 won an offline eval sweep (composite quality 0.734 to 0.744,
    /// wrong-shows down 27%, no must-show case lost), but that golden set badly under-represented
    /// real free-form typing: in production logs the same -1.5 floor withheld ~56% of completions,
    /// most of them perfectly usable (passed and suppressed completions sat on either side of the
    /// threshold with no quality difference). Under streaming the gate also paints a partial and
    /// then clears it, which reads as suggestions flickering away. Until the floor is recalibrated
    /// against a representative real-usage distribution, it stays opt-in via
    /// `cotabbyConfidenceFloorOverride`; the eval harness sets that key to measure with the gate on.
    static let defaultConfidenceFloor: Double = -.infinity
    /// Split confidence gate (TabType's measured finding): finishing a half-typed word is much
    /// easier for the model than guessing the next word after a space, so one bar for both either
    /// shows wrong next-word guesses or hides good word endings. The mid-word bar must sit lower
    /// (more permissive) than the word-boundary bar. Both ship OFF (-infinity) until each is
    /// calibrated separately against real-usage logs — the single-floor -1.5 lesson above applies
    /// to each bar independently. The split resolves in `makeGenerationOptions` from the same
    /// mid-word signal that sets `forceWordContinuation`, so the core's single-floor machinery
    /// is untouched.
    static let defaultConfidenceFloorMidWord: Double = -.infinity
    static let defaultConfidenceFloorWordBoundary: Double = -.infinity
    /// `defaults write` escape hatches for dogfooding and field diagnosis without a rebuild.
    static let confidenceFloorOverrideKey = "cotabbyConfidenceFloorOverride"
    static let confidenceFloorMidWordOverrideKey = "cotabbyConfidenceFloorMidWordOverride"
    static let confidenceFloorWordBoundaryOverrideKey = "cotabbyConfidenceFloorWordBoundaryOverride"
    static let argmaxStopDisabledKey = "cotabbyArgmaxStopDisabled"

    static func resolvedConfidenceFloor(_ defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: confidenceFloorOverrideKey) != nil else {
            return defaultConfidenceFloor
        }
        return defaults.double(forKey: confidenceFloorOverrideKey)
    }

    /// Split-gate resolution: mid-word carets (finishing a half-typed word) use the permissive
    /// bar, word-boundary carets (guessing the next word) the strict one. A set single-floor
    /// override still wins over both, so the eval harness's existing key keeps working; the
    /// split overrides only apply when no single-floor override is set.
    static func resolvedConfidenceFloor(isMidWord: Bool, _ defaults: UserDefaults = .standard) -> Double {
        if defaults.object(forKey: confidenceFloorOverrideKey) != nil {
            return defaults.double(forKey: confidenceFloorOverrideKey)
        }
        if isMidWord {
            guard defaults.object(forKey: confidenceFloorMidWordOverrideKey) != nil else {
                return defaultConfidenceFloorMidWord
            }
            return defaults.double(forKey: confidenceFloorMidWordOverrideKey)
        }
        guard defaults.object(forKey: confidenceFloorWordBoundaryOverrideKey) != nil else {
            return defaultConfidenceFloorWordBoundary
        }
        return defaults.double(forKey: confidenceFloorWordBoundaryOverrideKey)
    }

    /// Mirrors `resolvedConfidenceFloor`: injectable defaults so the disable toggle is testable
    /// against an isolated suite instead of process-global state.
    static func resolvedStopAtArgmaxEOG(_ defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: argmaxStopDisabledKey)
    }

    /// Prefills the prompt KV for the field the user just focused, so the first real suggestion
    /// there only decodes the typed delta instead of the whole cold prompt.
    ///
    /// The protocol default used to be a no-op here on the assumption that llama "keeps its KV
    /// cache hot", but a focus change resets the cached generation context and destroys the native
    /// sequence, so the first request in every field paid a full prefill. Best-effort by design:
    /// failures are swallowed (a missed warmup costs nothing the cold path would not have paid)
    /// and the tracker only records the prompt after the native decode actually succeeded.
    func prewarm(for request: SuggestionRequest) async {
        inflightPrewarmTask?.cancel()
        let cachedPrefixBytes = Self.reusablePrefixBytes(for: request)
        let options = Self.makeGenerationOptions(for: request)
        let task = Task { [runtimeManager] in
            do {
                try await runtimeManager.prefill(
                    prompt: request.prompt,
                    cachedPrefixBytes: cachedPrefixBytes,
                    options: options
                )
            } catch {
                CotabbyLogger.suggestion.debug(
                    "Llama prewarm skipped: \(error.localizedDescription)",
                    metadata: ["request_id": .string(request.requestID), "engine": .string("llama")]
                )
            }
        }
        inflightPrewarmTask = task
        await task.value
    }

    /// Executes one generation request and packages the raw and normalized result for the coordinator.
    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        try await generateSuggestion(for: request, onPartial: nil)
    }

    /// Streaming variant: cumulative raw partials from the decode thread are normalized and
    /// forwarded to `onPartial` on the main actor, so the coordinator can paint ghost text while
    /// the decode is still running. Empty normalizations are withheld (there is nothing useful to
    /// paint), and the returned result remains the authoritative final completion.
    func generateSuggestion(
        for request: SuggestionRequest,
        onPartial: (@MainActor (SuggestionResult) -> Void)?
    ) async throws -> SuggestionResult {
        let baseMetadata: Logger.Metadata = [
            "request_id": .string(request.requestID),
            "engine": .string("llama")
        ]
        do {
            // A still-running focus warmup must not make this request wait behind it on the
            // runtime's autocomplete lock; cancelling it aborts its native decode mid-chunk.
            inflightPrewarmTask?.cancel()
            inflightPrewarmTask = nil

            let startTime = Date()
            let cachedPrefixBytes = Self.reusablePrefixBytes(for: request)
            let hintDesc = String(cachedPrefixBytes)
            CotabbyLogger.suggestion.debug(
                "Llama generating",
                metadata: baseMetadata.merging([
                    "prompt_bytes": .stringConvertible(request.prompt.count),
                    "cache_hint_bytes": .string(hintDesc),
                    "max_tokens": .stringConvertible(request.maxPredictionTokens)
                ]) { _, new in new }
            )
            let options = Self.makeGenerationOptions(for: request)
            let output: LlamaGenerationOutput
            if let onPartial {
                output = try await runtimeManager.generate(
                    prompt: request.prompt,
                    cachedPrefixBytes: cachedPrefixBytes,
                    options: options,
                    onPartialRawText: { raw in
                        // Decode-thread callback; normalization and delivery hop to the main
                        // actor. Hops are independent tasks, so a shorter cumulative can land
                        // after a longer one — the coordinator's monotonic render policy makes
                        // that harmless.
                        Task { @MainActor in
                            let normalized = SuggestionTextNormalizer.normalizeDetailed(raw, for: request).text
                            guard !normalized.isEmpty else {
                                return
                            }
                            onPartial(SuggestionResult(
                                generation: request.generation,
                                rawText: raw,
                                text: normalized,
                                latency: Date().timeIntervalSince(startTime),
                                spacingIsExact: true
                            ))
                        }
                    }
                )
            } else {
                output = try await runtimeManager.generate(
                    prompt: request.prompt,
                    cachedPrefixBytes: cachedPrefixBytes,
                    options: options
                )
            }
            try Task.checkCancellation()

            let rawSuggestion = output.text
            // A confidence-suppressed completion never reaches the normalizer (the runtime already
            // withheld the text); attribute the real reason instead of "the model produced nothing".
            // Streamed partials are pre-gate by nature: a completion the floor later withholds can
            // briefly paint and then clear, which is the same contract as any other final-result
            // suppression under streaming.
            let normalization = output.suppressedByLowConfidence
                ? SuggestionNormalizationResult(text: "", suppression: .lowConfidence)
                : SuggestionTextNormalizer.normalizeDetailed(rawSuggestion, for: request)
            let normalizedSuggestion = normalization.text
            let latency = Date().timeIntervalSince(startTime)
            let rawChars = rawSuggestion.count
            let normalizedChars = normalizedSuggestion.count
            let latencyMs = Int(latency * 1000)
            // `suppression_reason` distinguishes an empty ghost text caused by the model producing
            // nothing from one a filter dropped — the join key for judging decode quality on device.
            let suppressionReason = normalization.suppression?.rawValue ?? "none"
            let averageLogprobDescription = output.averageLogprob.map { String(format: "%.3f", $0) } ?? "off"
            CotabbyLogger.suggestion.debug(
                "Llama generated",
                metadata: baseMetadata.merging([
                    "raw_chars": .stringConvertible(rawChars),
                    "normalized_chars": .stringConvertible(normalizedChars),
                    "suppression_reason": .string(suppressionReason),
                    "avg_logprob": .string(averageLogprobDescription),
                    "latency_ms": .stringConvertible(latencyMs)
                ]) { _, new in new }
            )
            CotabbyLogger.llmIO.debug(
                "llama generation",
                metadata: baseMetadata.merging([
                    "prompt": .string(request.prompt),
                    "completion_raw": .string(rawSuggestion),
                    "completion_normalized": .string(normalizedSuggestion),
                    "prompt_bytes": .stringConvertible(request.prompt.utf8.count),
                    "raw_chars": .stringConvertible(rawChars),
                    "normalized_chars": .stringConvertible(normalizedChars),
                    "suppression_reason": .string(suppressionReason),
                    "avg_logprob": .string(averageLogprobDescription),
                    "latency_ms": .stringConvertible(latencyMs),
                    "cache_hint_bytes": .string(hintDesc),
                    "max_tokens": .stringConvertible(request.maxPredictionTokens)
                ]) { _, new in new }
            )
            return SuggestionResult(
                generation: request.generation,
                rawText: rawSuggestion,
                text: normalizedSuggestion,
                latency: latency,
                suppressionReason: normalization.suppression?.rawValue,
                // A base model's completion follows the prompt text exactly: its leading space (or
                // the lack of one) is the model's own word boundary.
                spacingIsExact: true
            )
        } catch is CancellationError {
            CotabbyLogger.suggestion.debug("Llama generation cancelled", metadata: baseMetadata)
            throw SuggestionClientError.cancelled
        } catch LlamaRuntimeError.cancelled {
            // A cancelled generation is NOT a runtime failure, so it must not reset the KV cache.
            // `LlamaRuntimeManager.generate` surfaces an outer-Task cancellation as
            // `LlamaRuntimeError.cancelled` (its `catch is CancellationError` rethrows it so callers
            // share one error vocabulary). Without this branch that case falls through to the generic
            // `LlamaRuntimeError` handler below and wipes the native KV sequence on every cancel.
            //
            // During fast typing nearly every keystroke supersedes the previous in-flight generation,
            // so that path fired ~twice a second — each time synchronously destroying the prompt KV on
            // the main actor (contending with the keystroke-delivery run loop) and forcing the next
            // keystroke to re-decode the whole prompt from scratch. The cooperative cancel inside
            // `LlamaRuntimeCore.generate` closes the cancelled operation's abort target and retains
            // its validated prompt descriptor. The next request restores that prefix before reuse,
            // or rebuilds on a cache miss. Keep the sequence available for that decision rather
            // than discarding every cancelled request's reusable context here.
            CotabbyLogger.suggestion.debug("Llama generation cancelled (runtime task)", metadata: baseMetadata)
            throw SuggestionClientError.cancelled
        } catch let error as LlamaRuntimeError {
            CotabbyLogger.suggestion.error(
                "Llama runtime error, resetting cache: \(error.localizedDescription)",
                metadata: baseMetadata
            )
            await resetCachedGenerationContext()
            throw SuggestionClientError.unavailable(error.localizedDescription)
        } catch let error as SuggestionClientError {
            CotabbyLogger.suggestion.error(
                "Suggestion client error, resetting cache: \(error.localizedDescription)",
                metadata: baseMetadata
            )
            await resetCachedGenerationContext()
            throw error
        } catch {
            CotabbyLogger.suggestion.error(
                "Unexpected generation error, resetting cache: \(error.localizedDescription)",
                metadata: baseMetadata
            )
            await resetCachedGenerationContext()
            throw SuggestionClientError.generationFailed(error.localizedDescription)
        }
    }

    /// Clears both the Swift-side hint tracker and the native llama KV cache.
    /// The tracker reset is synchronous because it protects the next request from advertising
    /// stale reuse; awaiting the runtime reset keeps native KV invalidation ordered before the next
    /// generation request that crosses this engine boundary.
    func resetCachedGenerationContext() async {
        // The editing context moved on, so a warmup for the previous field's prompt is stale.
        inflightPrewarmTask?.cancel()
        inflightPrewarmTask = nil
        runtimeManager.resetPromptCache()
    }

    /// One shared mapping from a request to engine options so prewarm prefills decode under the
    /// exact sampling fingerprint the following generation will validate its KV reuse against.
    private static func makeGenerationOptions(for request: SuggestionRequest) -> LlamaGenerationOptions {
        // The mid-word signal is computed once and shared: it constrains the first token to
        // continue the current word AND picks the split confidence bar (see
        // `resolvedConfidenceFloor(isMidWord:)`). A caret mid-word is finishing a half-typed
        // word (easy for the model, permissive bar); a caret at a boundary is guessing the
        // next word (hard, strict bar).
        let isMidWord = MidWordContinuationPolicy.shouldForceContinuation(
            precedingText: request.context.precedingText,
            trailingText: request.context.trailingText
        )
        return LlamaGenerationOptions(
            maxPredictionTokens: request.maxPredictionTokens,
            temperature: request.temperature,
            topK: request.topK,
            topP: request.topP,
            minP: request.minP,
            repetitionPenalty: request.repetitionPenalty,
            seed: request.randomSeed,
            // A single-line suggestion stops at the model's line break rather than masking it: see
            // `LlamaGenerationOptions.stopAtLineBreak`. The normalizer keeps only the first line.
            singleLine: false,
            stopAtLineBreak: !request.isMultiLineEnabled,
            forceWordContinuation: isMidWord,
            confidenceFloor: resolvedConfidenceFloor(isMidWord: isMidWord),
            sentenceStopMinimumWords: request.wordRange?.lowWords ?? 0,
            stopAtArgmaxEOG: resolvedStopAtArgmaxEOG()
        )
    }
}

extension LlamaSuggestionEngine: SuggestionGenerating {
    /// The whole prompt is offered for reuse; `LlamaRuntimeCore` keeps only the bytes and tokens
    /// that match what it last decoded under the same sampling fingerprint. A Swift-side tracker
    /// used to narrow this by field frame and by the last *finished* request, which zeroed reuse
    /// whenever a field grew a line or typing cancelled requests, forcing ~1s full prefills.
    static func reusablePrefixBytes(for request: SuggestionRequest) -> Int {
        request.prompt.utf8.count
    }
}
