import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Wraps the raw llama runtime with prompt/result normalization that is specific to inline
/// completion. This is where raw generated text becomes a short suggestion Tabby can safely show.
///
/// Keeps prompt normalization separate from the raw llama runtime.
/// That separation matters because prompt strategy changes far more often than model lifecycle code.
@MainActor
final class LlamaSuggestionEngine {
    private let runtimeManager: LlamaRuntimeManager
    private var promptCacheHintTracker = LlamaPromptCacheHintTracker()

    init(runtimeManager: LlamaRuntimeManager) {
        self.runtimeManager = runtimeManager
    }

    /// Executes one generation request and packages the raw and normalized result for the coordinator.
    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        do {
            let startTime = Date()
            let cachedPrefixBytes = promptCacheHintTracker.cachedPrefixBytes(for: request)
            let hintDesc = cachedPrefixBytes.map(String.init) ?? "none"
            TabbyLogger.suggestion.debug(
                "Llama generating: prompt=\(request.prompt.count)B cache_hint=\(hintDesc) max_tokens=\(request.maxPredictionTokens)"
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
                    seed: request.randomSeed
                )
            )
            try Task.checkCancellation()

            promptCacheHintTracker.recordSuccessfulRequest(request)
            let normalizedSuggestion = SuggestionTextNormalizer.normalize(rawSuggestion, for: request)
            let latency = Date().timeIntervalSince(startTime)
            TabbyLogger.suggestion.debug("Llama generated: raw=\(rawSuggestion.count) chars, normalized=\(normalizedSuggestion.count) chars, latency=\(Int(latency * 1000))ms")
            return SuggestionResult(
                generation: request.generation,
                rawText: rawSuggestion,
                text: normalizedSuggestion,
                latency: latency
            )
        } catch is CancellationError {
            TabbyLogger.suggestion.debug("Llama generation cancelled")
            throw SuggestionClientError.cancelled
        } catch let error as LlamaRuntimeError {
            TabbyLogger.suggestion.error("Llama runtime error, resetting cache: \(error.localizedDescription)")
            await resetCachedGenerationContext()
            throw SuggestionClientError.unavailable(error.localizedDescription)
        } catch let error as SuggestionClientError {
            TabbyLogger.suggestion.error("Suggestion client error, resetting cache: \(error.localizedDescription)")
            await resetCachedGenerationContext()
            throw error
        } catch {
            TabbyLogger.suggestion.error("Unexpected generation error, resetting cache: \(error.localizedDescription)")
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
        await runtimeManager.resetPromptCache()
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
