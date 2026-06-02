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

    /// UserDefaults key (no UI) that routes llama generation through the deterministic constrained
    /// decoder instead of the engine's stochastic sampler. Default-off: decode quality can only be
    /// judged with a real model in a real field, so this stays a hidden developer/dogfood toggle
    /// until it is validated on device and promoted to the default.
    private static let constrainedDecoderDefaultsKey = "cotabbyConstrainedDecoderEnabled"
    private static var isConstrainedDecoderEnabled: Bool {
        UserDefaults.standard.bool(forKey: constrainedDecoderDefaultsKey)
    }

    /// UserDefaults key (no UI) for the constrained decoder's beam width. Default 1 keeps the existing
    /// single-path greedy decode; a value > 1 runs a multi-branch beam search. Paired with the
    /// constrained-decoder flag as a hidden developer/dogfood knob until validated on device.
    private static let constrainedBeamWidthDefaultsKey = "cotabbyConstrainedBeamWidth"
    private static var constrainedBeamWidth: Int {
        let stored = UserDefaults.standard.integer(forKey: constrainedBeamWidthDefaultsKey)
        return stored > 0 ? stored : 1
    }

    init(runtimeManager: LlamaRuntimeGenerating) {
        self.runtimeManager = runtimeManager
    }

    /// Executes one generation request and packages the raw and normalized result for the coordinator.
    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        let baseMetadata: Logger.Metadata = [
            "request_id": .string(request.requestID),
            "engine": .string("llama")
        ]
        do {
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
                options: LlamaGenerationOptions(
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
                    ),
                    useConstrainedDecoder: Self.isConstrainedDecoderEnabled,
                    beamWidth: Self.constrainedBeamWidth
                )
            )
            try Task.checkCancellation()

            promptCacheHintTracker.recordSuccessfulRequest(request)
            let normalizedSuggestion = SuggestionTextNormalizer.normalize(rawSuggestion, for: request)
            let latency = Date().timeIntervalSince(startTime)
            let rawChars = rawSuggestion.count
            let normalizedChars = normalizedSuggestion.count
            let latencyMs = Int(latency * 1000)
            CotabbyLogger.suggestion.debug(
                "Llama generated",
                metadata: baseMetadata.merging([
                    "raw_chars": .stringConvertible(rawChars),
                    "normalized_chars": .stringConvertible(normalizedChars),
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
        promptCacheHintTracker.reset()
        runtimeManager.resetPromptCache()
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
