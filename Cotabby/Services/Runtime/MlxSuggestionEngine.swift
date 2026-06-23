import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Adapts the MLX runtime to Cotabby's inline-completion pipeline.
///
/// The runtime manager speaks in prompts and backend options. The suggestion engine speaks in
/// `SuggestionRequest` and `SuggestionResult`, so it owns prompt-cache hints, normalization,
/// logging, and error vocabulary. This mirrors the llama path and keeps the coordinator unaware of
/// concrete backend details.
@MainActor
final class MlxSuggestionEngine {
    private let runtimeManager: MlxRuntimeGenerating
    private var promptCacheHintTracker = MlxPromptCacheHintTracker()

    init(runtimeManager: MlxRuntimeGenerating) {
        self.runtimeManager = runtimeManager
    }

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        let baseMetadata: Logger.Metadata = [
            "request_id": .string(request.requestID),
            "engine": .string("mlx")
        ]
        do {
            let startTime = Date()
            let cachedPrefixBytes = promptCacheHintTracker.cachedPrefixBytes(for: request)
            let hintDesc = cachedPrefixBytes.map(String.init) ?? "none"
            CotabbyLogger.suggestion.debug(
                "MLX generating",
                metadata: baseMetadata.merging([
                    "prompt_bytes": .stringConvertible(request.prompt.utf8.count),
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
                    )
                )
            )
            try Task.checkCancellation()

            promptCacheHintTracker.recordSuccessfulRequest(request)
            let normalization = SuggestionTextNormalizer.normalizeDetailed(rawSuggestion, for: request)
            let normalizedSuggestion = normalization.text
            let latency = Date().timeIntervalSince(startTime)
            let latencyMs = Int(latency * 1000)
            let suppressionReason = normalization.suppression?.rawValue ?? "none"

            CotabbyLogger.suggestion.debug(
                "MLX generated",
                metadata: baseMetadata.merging([
                    "raw_chars": .stringConvertible(rawSuggestion.count),
                    "normalized_chars": .stringConvertible(normalizedSuggestion.count),
                    "suppression_reason": .string(suppressionReason),
                    "latency_ms": .stringConvertible(latencyMs)
                ]) { _, new in new }
            )
            CotabbyLogger.llmIO.debug(
                "mlx generation",
                metadata: baseMetadata.merging([
                    "prompt": .string(request.prompt),
                    "completion_raw": .string(rawSuggestion),
                    "completion_normalized": .string(normalizedSuggestion),
                    "prompt_bytes": .stringConvertible(request.prompt.utf8.count),
                    "raw_chars": .stringConvertible(rawSuggestion.count),
                    "normalized_chars": .stringConvertible(normalizedSuggestion.count),
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
            CotabbyLogger.suggestion.debug("MLX generation cancelled", metadata: baseMetadata)
            throw SuggestionClientError.cancelled
        } catch MlxRuntimeError.cancelled {
            CotabbyLogger.suggestion.debug("MLX generation cancelled (runtime task)", metadata: baseMetadata)
            throw SuggestionClientError.cancelled
        } catch let error as MlxRuntimeError {
            CotabbyLogger.suggestion.error(
                "MLX runtime error, resetting cache: \(error.localizedDescription)",
                metadata: baseMetadata
            )
            await resetCachedGenerationContext()
            throw SuggestionClientError.unavailable(error.localizedDescription)
        } catch let error as SuggestionClientError {
            CotabbyLogger.suggestion.error(
                "MLX suggestion client error, resetting cache: \(error.localizedDescription)",
                metadata: baseMetadata
            )
            await resetCachedGenerationContext()
            throw error
        } catch {
            CotabbyLogger.suggestion.error(
                "Unexpected MLX generation error, resetting cache: \(error.localizedDescription)",
                metadata: baseMetadata
            )
            await resetCachedGenerationContext()
            throw SuggestionClientError.generationFailed(error.localizedDescription)
        }
    }

    func resetCachedGenerationContext() async {
        promptCacheHintTracker.reset()
        runtimeManager.resetPromptCache()
    }
}

extension MlxSuggestionEngine: SuggestionGenerating {}

/// Tracks the previous successful MLX request so the engine can advertise a byte-prefix reuse hint
/// to `MlxRuntimeManager`. The runtime still validates token-level reuse after tokenization; this
/// Swift-side hint is just a cheap way to skip work when the editing context obviously changed.
struct MlxPromptCacheHintTracker: Equatable {
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

        return MlxPromptCachePlanner.commonPrefixCount(lastRequest.promptBytes, nextRequest.promptBytes)
    }

    mutating func recordSuccessfulRequest(_ request: SuggestionRequest) {
        lastRequest = CachedRequest(request: request)
    }

    mutating func reset() {
        lastRequest = nil
    }
}

private extension MlxPromptCacheHintTracker {
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
