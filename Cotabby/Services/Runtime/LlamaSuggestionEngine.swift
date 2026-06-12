import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Wraps the raw llama runtime with prompt/result normalization that is specific to inline
/// completion. This is where raw generated text becomes a short suggestion Cotabby can safely show.
///
/// Keeps prompt normalization separate from the raw llama runtime.
/// That separation matters because prompt strategy changes far more often than model lifecycle code.
@MainActor
final class LlamaSuggestionEngine {
    private let runtimeManager: LlamaRuntimeGenerating
    private var promptCacheHintTracker = LlamaPromptCacheHintTracker()
    /// The focus-time warmup in flight, if any. A real generation cancels it on entry so it never
    /// queues behind a warmup for a prompt the user has already typed past.
    private var inflightPrewarmTask: Task<Void, Never>?

    init(runtimeManager: LlamaRuntimeGenerating) {
        self.runtimeManager = runtimeManager
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
        let cachedPrefixBytes = promptCacheHintTracker.cachedPrefixBytes(for: request)
        let options = Self.makeGenerationOptions(for: request)
        let task = Task { [weak self, runtimeManager] in
            do {
                try await runtimeManager.prefill(
                    prompt: request.prompt,
                    cachedPrefixBytes: cachedPrefixBytes,
                    options: options
                )
                guard !Task.isCancelled else {
                    return
                }
                self?.promptCacheHintTracker.recordSuccessfulRequest(request)
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
            let cachedPrefixBytes = promptCacheHintTracker.cachedPrefixBytes(for: request)
            let hintDesc = cachedPrefixBytes.map(String.init) ?? "none"
            CotabbyLogger.suggestion.debug(
                "Llama generating",
                metadata: baseMetadata.merging([
                    "prompt_bytes": .stringConvertible(request.prompt.count),
                    "cache_hint_bytes": .string(hintDesc),
                    "max_tokens": .stringConvertible(request.maxPredictionTokens)
                ]) { _, new in new }
            )
            let rawSuggestion = try await runtimeManager.generate(
                prompt: request.prompt,
                cachedPrefixBytes: cachedPrefixBytes,
                options: Self.makeGenerationOptions(for: request)
            )
            try Task.checkCancellation()

            promptCacheHintTracker.recordSuccessfulRequest(request)
            let normalization = SuggestionTextNormalizer.normalizeDetailed(rawSuggestion, for: request)
            let normalizedSuggestion = normalization.text
            let latency = Date().timeIntervalSince(startTime)
            let rawChars = rawSuggestion.count
            let normalizedChars = normalizedSuggestion.count
            let latencyMs = Int(latency * 1000)
            // `suppression_reason` distinguishes an empty ghost text caused by the model producing
            // nothing from one a filter dropped — the join key for judging decode quality on device.
            let suppressionReason = normalization.suppression?.rawValue ?? "none"
            CotabbyLogger.suggestion.debug(
                "Llama generated",
                metadata: baseMetadata.merging([
                    "raw_chars": .stringConvertible(rawChars),
                    "normalized_chars": .stringConvertible(normalizedChars),
                    "suppression_reason": .string(suppressionReason),
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
                    "latency_ms": .stringConvertible(latencyMs),
                    "cache_hint_bytes": .string(hintDesc),
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
            // `LlamaRuntimeCore.generate` already unwound cleanly (its KV-trim defer restored
            // prompt-only state), so the cache is still valid and reusable. Route this to the same
            // quiet path as `CancellationError` and leave the cache intact.
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
        promptCacheHintTracker.reset()
        runtimeManager.resetPromptCache()
    }

    /// One shared mapping from a request to engine options so prewarm prefills decode under the
    /// exact sampling fingerprint the following generation will validate its KV reuse against.
    private static func makeGenerationOptions(for request: SuggestionRequest) -> LlamaGenerationOptions {
        LlamaGenerationOptions(
            maxPredictionTokens: request.maxPredictionTokens,
            temperature: request.temperature,
            topK: request.topK,
            topP: request.topP,
            minP: request.minP,
            repetitionPenalty: request.repetitionPenalty,
            seed: request.randomSeed,
            singleLine: !request.isMultiLineEnabled,
            forceWordContinuation: MidWordContinuationPolicy.shouldForceContinuation(
                precedingText: request.context.precedingText,
                trailingText: request.context.trailingText
            )
        )
    }
}

extension LlamaSuggestionEngine: SuggestionGenerating {}

/// Tracks the last successful llama prompt so the engine can pass a conservative byte-prefix hint
/// into `LlamaRuntimeManager.generate`. This type deliberately does not own correctness: native KV
/// state is still validated by `LlamaRuntimeCore` after tokenization.
struct LlamaPromptCacheHintTracker: Equatable {
    private var lastRequest: CachedRequest?

    mutating func cachedPrefixBytes(for request: SuggestionRequest) -> Int? {
        let nextRequest = CachedRequest(request: request)
        guard let lastRequest else {
            return nil
        }

        guard lastRequest.focusKey == nextRequest.focusKey,
              lastRequest.samplingFingerprint == nextRequest.samplingFingerprint
        else {
            self.lastRequest = nil
            return nil
        }

        return Self.commonPrefixByteCount(lastRequest.promptBytes, nextRequest.promptBytes)
    }

    mutating func recordSuccessfulRequest(_ request: SuggestionRequest) {
        lastRequest = CachedRequest(request: request)
    }

    mutating func reset() {
        lastRequest = nil
    }

    private static func commonPrefixByteCount(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        var index = 0
        let limit = min(lhs.count, rhs.count)

        while index < limit, lhs[index] == rhs[index] {
            index += 1
        }

        return index
    }
}

private extension LlamaPromptCacheHintTracker {
    struct CachedRequest: Equatable {
        let focusKey: FocusKey
        let samplingFingerprint: SamplingFingerprint
        let promptBytes: [UInt8]

        init(request: SuggestionRequest) {
            focusKey = FocusKey(context: request.context)
            samplingFingerprint = SamplingFingerprint(request: request)
            promptBytes = Array(request.prompt.utf8)
        }
    }

    struct FocusKey: Equatable {
        let bundleIdentifier: String
        let processIdentifier: Int32
        let role: String
        let subrole: String?
        let fieldAnchor: FieldAnchor

        init(context: FocusedInputContext) {
            bundleIdentifier = context.bundleIdentifier
            processIdentifier = context.processIdentifier
            role = context.role
            subrole = context.subrole
            fieldAnchor = FieldAnchor(
                inputFrame: context.inputFrameRect,
                fallbackElementIdentifier: context.elementIdentifier
            )
        }
    }

    struct FieldAnchor: Equatable {
        let roundedInputFrame: RoundedRect?
        let fallbackElementIdentifier: String?

        nonisolated init(inputFrame: CGRect?, fallbackElementIdentifier: String) {
            roundedInputFrame = inputFrame.map(RoundedRect.init(rect:))
            self.fallbackElementIdentifier = roundedInputFrame == nil ? fallbackElementIdentifier : nil
        }
    }

    struct RoundedRect: Equatable {
        let minX: Int
        let minY: Int
        let width: Int
        let height: Int

        nonisolated init(rect: CGRect) {
            minX = Int(rect.minX.rounded())
            minY = Int(rect.minY.rounded())
            width = Int(rect.width.rounded())
            height = Int(rect.height.rounded())
        }
    }

    struct SamplingFingerprint: Equatable {
        let maxPredictionTokens: Int
        let temperature: Double
        let topK: Int
        let topP: Double
        let minP: Double
        let repetitionPenalty: Double
        let randomSeed: UInt32?

        init(request: SuggestionRequest) {
            maxPredictionTokens = request.maxPredictionTokens
            temperature = request.temperature
            topK = request.topK
            topP = request.topP
            minP = request.minP
            repetitionPenalty = request.repetitionPenalty
            randomSeed = request.randomSeed
        }
    }
}
