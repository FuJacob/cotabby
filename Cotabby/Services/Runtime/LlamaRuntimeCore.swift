import Foundation
import Logging
import CotabbyInference

/// File overview:
/// Owns the C++ inference engine and manages the autocomplete KV cache lifecycle. This is the
/// lowest-level runtime boundary in the app: it loads the GGUF model, manages concurrent
/// sequences, tokenizes prompts, samples continuations, and frees native resources on shutdown.
///
/// The engine handles thread safety internally via per-sequence mutexes. This class is
/// `@unchecked Sendable` rather than an `actor` so that `generate()` (autocomplete) and
/// `summarize()` (visual context) can run on separate sequences concurrently.
/// `autocompleteLock` serializes autocomplete-specific KV cache state; summary uses
/// ephemeral sequences with no shared state. A separate `lifecycleCondition` prevents
/// `shutdown()` from unloading the model while any operation is still in flight.

/// Immutable runtime metadata captured after a model has been successfully prepared.
struct PreparedLlamaRuntime: Sendable {
    let resolvedRuntime: ResolvedLlamaRuntime
    let contextWindowTokens: Int
    let batchSize: Int
    let threadCount: Int
    let gpuLayerCount: Int
    let backendName: String
}

nonisolated final class LlamaRuntimeCore: @unchecked Sendable {
    private var engine = CotabbyInferenceEngine()
    private var preparedRuntime: PreparedLlamaRuntime?

    private let autocompleteLock = NSLock()
    private var autocompleteSequenceID: Int32 = -1
    private var autocompletePromptBytes: [UInt8] = []
    private var autocompletePromptTokens: [Int32] = []
    private var autocompleteSamplingFingerprint: SamplingFingerprint?

    /// Coordinates model lifecycle with in-flight operations. `generate()` and `summarize()`
    /// increment the active count on entry and decrement on exit. `shutdown()` sets the
    /// shutting-down flag and blocks until all active operations finish before unloading.
    private let lifecycleCondition = NSCondition()
    private var activeOperationCount = 0
    private var isShuttingDown = false

    // MARK: - Model lifecycle

    /// Loads the requested model once and records the runtime characteristics needed for diagnostics.
    func prepare(
        resolvedRuntime: ResolvedLlamaRuntime,
        configuration: LlamaRuntimeConfiguration
    ) throws -> PreparedLlamaRuntime {
        if let preparedRuntime,
           preparedRuntime.resolvedRuntime.modelFileURL == resolvedRuntime.modelFileURL {
            return preparedRuntime
        }

        if preparedRuntime != nil {
            shutdown()
        }

        CotabbyLogger.runtime.info(
            "Loading model",
            metadata: [
                "model_path": .string(resolvedRuntime.modelFileURL.path),
                "context_window_tokens": .stringConvertible(configuration.contextWindowTokens),
                "batch_size": .stringConvertible(configuration.batchSize),
                "gpu_layers": .stringConvertible(configuration.gpuLayerCount)
            ]
        )
        let status = engine.loadModel(
            resolvedRuntime.modelFileURL.path,
            configuration.gpuLayerCount,
            configuration.contextWindowTokens,
            configuration.batchSize
        )

        guard status == .ok else {
            CotabbyLogger.runtime.error(
                "Model load failed",
                metadata: [
                    "model": .string(resolvedRuntime.modelDisplayName),
                    "model_path": .string(resolvedRuntime.modelFileURL.path)
                ]
            )
            throw LlamaRuntimeError.unavailable(
                "Unable to load \(resolvedRuntime.modelDisplayName) with CotabbyInferenceEngine."
            )
        }

        let result = PreparedLlamaRuntime(
            resolvedRuntime: resolvedRuntime,
            contextWindowTokens: Int(engine.getContextWindowTokens()),
            batchSize: Int(engine.getBatchSize()),
            threadCount: Int(engine.getThreadCount()),
            gpuLayerCount: Int(engine.getGPULayerCount()),
            backendName: "CotabbyInferenceEngine (llama.cpp in-process)"
        )
        self.preparedRuntime = result
        CotabbyLogger.runtime.info(
            "Model loaded",
            metadata: [
                "model": .string(resolvedRuntime.modelDisplayName),
                "context_window_tokens": .stringConvertible(result.contextWindowTokens),
                "batch_size": .stringConvertible(result.batchSize),
                "threads": .stringConvertible(result.threadCount),
                "gpu_layers": .stringConvertible(result.gpuLayerCount),
                "backend": .string(result.backendName)
            ]
        )
        return result
    }

    // MARK: - Autocomplete generation

    /// Prepares the prompt context, reusing cached KV state when safe, then samples a short completion.
    /// Holds `autocompleteLock` for the full call to prevent concurrent KV cache mutation.
    func generate(
        prompt: String,
        cachedPrefixBytes: Int? = nil,
        options: LlamaGenerationOptions
    ) throws -> String {
        guard let preparedRuntime else {
            throw LlamaRuntimeError.unavailable("The llama model is not loaded.")
        }

        lifecycleCondition.lock()
        guard !isShuttingDown else {
            lifecycleCondition.unlock()
            throw LlamaRuntimeError.unavailable("The runtime is shutting down.")
        }
        activeOperationCount += 1
        lifecycleCondition.unlock()

        defer {
            lifecycleCondition.lock()
            activeOperationCount -= 1
            lifecycleCondition.broadcast()
            lifecycleCondition.unlock()
        }

        let promptBytes = Array(prompt.utf8)
        let allPromptTokens = tokenize(prompt)
        guard !allPromptTokens.isEmpty else {
            CotabbyLogger.runtime.error(
                "Tokenization returned no prompt tokens",
                metadata: ["prompt_bytes": .stringConvertible(promptBytes.count)]
            )
            throw LlamaRuntimeError.generationFailed("Tokenization returned no prompt tokens.")
        }
        CotabbyLogger.runtime.debug(
            "Decode start",
            metadata: [
                "kind": .string("generate"),
                "prompt_tokens": .stringConvertible(allPromptTokens.count),
                "max_tokens": .stringConvertible(options.maxPredictionTokens),
                "cached_prefix_bytes": .string(cachedPrefixBytes.map(String.init) ?? "none")
            ]
        )

        let maxPromptTokens = max(1, preparedRuntime.contextWindowTokens - options.maxPredictionTokens)
        var promptTokens: [Int32]
        var adjustedCachedPrefixBytes: Int?
        if allPromptTokens.count > maxPromptTokens {
            promptTokens = Array(allPromptTokens.suffix(maxPromptTokens))
            adjustedCachedPrefixBytes = nil
        } else {
            promptTokens = allPromptTokens
            adjustedCachedPrefixBytes = cachedPrefixBytes
        }

        let fingerprint = SamplingFingerprint(options: options)

        autocompleteLock.lock()
        defer { autocompleteLock.unlock() }

        let sequenceID = try obtainAutocompleteSequence(
            promptTokens: promptTokens,
            promptBytes: promptBytes,
            fingerprint: fingerprint,
            cachedPrefixBytes: adjustedCachedPrefixBytes,
            options: options
        )

        defer {
            // Trim sampled tokens so KV retains only the prompt for the next request.
            _ = engine.trimKV(sequenceID, Int32(promptTokens.count))
            autocompletePromptBytes = promptBytes
            autocompletePromptTokens = promptTokens
            autocompleteSamplingFingerprint = fingerprint
        }

        // The KV-trim defer above runs after the decoder returns, restoring prompt-only KV state for
        // the next request. Token selection is delegated to the engine's built-in sampler.
        return runEngineSampledDecode(sequenceID: sequenceID, options: options)
    }

    // MARK: - Decoders

    /// The shipping decoder: delegates token selection to the engine's built-in sampler
    /// (`sampleNext`), which applies temperature / top-k / top-p / min-p and commits each token.
    private func runEngineSampledDecode(sequenceID: Int32, options: LlamaGenerationOptions) -> String {
        var generatedText = ""
        var tokensGenerated = 0
        var sumLogprob = 0.0
        var stopReason = "budget_exhausted"

        for _ in 0 ..< options.maxPredictionTokens {
            // Cooperative cancellation: when the wrapping Task is cancelled (caller hit a new
            // keystroke, focus changed, Compose started), bail before the next sampleNext call so
            // we release `autocompleteLock` instead of running the full prediction budget and
            // making the next autocomplete wait behind us.
            if Task.isCancelled {
                stopReason = "cancelled"
                break
            }

            let result = engine.sampleNext(sequenceID)

            if result.was_cancelled {
                stopReason = "engine_cancelled"
                break
            }
            if result.is_eos {
                stopReason = "eos"
                break
            }

            let piece = Self.extractPiece(result)
            generatedText += piece
            tokensGenerated += 1
            sumLogprob += Double(result.logprob)
        }

        CotabbyLogger.runtime.debug(
            "Decode end",
            metadata: [
                "kind": .string("generate"),
                "tokens_generated": .stringConvertible(tokensGenerated),
                "chars_generated": .stringConvertible(generatedText.count),
                "stop_reason": .string(stopReason)
            ]
        )

        if Self.shouldSuppress(sumLogprob: sumLogprob, tokensGenerated: tokensGenerated, options: options) {
            return ""
        }
        return generatedText
    }

    /// Low-confidence gate for the sampled decoder: drop completions the model itself was unsure
    /// about. Disabled by default (confidenceFloor == -infinity). The KV-trim defer in `generate`
    /// still runs because the caller returns "" rather than throwing.
    private static func shouldSuppress(
        sumLogprob: Double,
        tokensGenerated: Int,
        options: LlamaGenerationOptions
    ) -> Bool {
        guard tokensGenerated > 0 else { return false }
        let averageLogprob = sumLogprob / Double(tokensGenerated)
        let suppress = ConfidenceSuppressionPolicy.shouldSuppress(
            averageLogprob: averageLogprob,
            floor: options.confidenceFloor
        )
        if suppress {
            CotabbyLogger.runtime.debug(
                "Suppressed low-confidence completion",
                metadata: [
                    "tokens_generated": .stringConvertible(tokensGenerated),
                    "avg_logprob": .stringConvertible(averageLogprob)
                ]
            )
        }
        return suppress
    }

    // MARK: - Cache and lifecycle

    /// Drops the reusable autocomplete sequence while keeping the loaded model alive.
    func resetPromptCache() {
        autocompleteLock.lock()
        defer { autocompleteLock.unlock() }

        if autocompleteSequenceID >= 0 {
            CotabbyLogger.runtime.debug(
                "Prompt cache reset",
                metadata: ["sequence_id": .stringConvertible(autocompleteSequenceID)]
            )
            engine.destroySequence(autocompleteSequenceID)
        }
        autocompleteSequenceID = -1
        autocompletePromptBytes = []
        autocompletePromptTokens = []
        autocompleteSamplingFingerprint = nil
    }

    /// Waits for all in-flight `generate()` and `summarize()` calls to finish, then frees all
    /// sequences and the loaded model. Blocking is intentional: callers should dispatch this off
    /// the main thread via `Task.detached` when UI responsiveness matters.
    ///
    /// `timeoutSeconds` caps the wait for in-flight work to drain. On timeout we still proceed
    /// with `engine.unloadModel()` so the caller (typically `applicationWillTerminate`) does not
    /// hang the main thread on a runaway generation. A nil timeout waits indefinitely.
    func shutdown(timeoutSeconds: TimeInterval? = nil) {
        CotabbyLogger.runtime.info(
            "Runtime shutdown requested",
            metadata: [
                "timeout_seconds": .string(timeoutSeconds.map { String(format: "%.1f", $0) } ?? "unbounded")
            ]
        )
        lifecycleCondition.lock()
        isShuttingDown = true

        if let timeoutSeconds {
            let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
            while activeOperationCount > 0 {
                if !lifecycleCondition.wait(until: deadline) { break }
            }
        } else {
            while activeOperationCount > 0 {
                lifecycleCondition.wait()
            }
        }
        lifecycleCondition.unlock()

        resetPromptCache()
        engine.unloadModel()
        preparedRuntime = nil
        CotabbyLogger.runtime.info("Runtime shutdown complete")

        lifecycleCondition.lock()
        isShuttingDown = false
        lifecycleCondition.unlock()
    }

    // MARK: - Private: autocomplete sequence management

    /// Returns a sequence ID with KV state representing the prompt. Reuses cached KV when the
    /// new prompt shares a validated prefix with the previous one.
    /// Must be called while holding `autocompleteLock`.
    private func obtainAutocompleteSequence(
        promptTokens: [Int32],
        promptBytes: [UInt8],
        fingerprint: SamplingFingerprint,
        cachedPrefixBytes: Int?,
        options: LlamaGenerationOptions
    ) throws -> Int32 {
        if autocompleteSequenceID >= 0,
           let cachedPrefixBytes, cachedPrefixBytes > 0,
           autocompleteSamplingFingerprint == fingerprint {

            let confirmedCommonBytes = min(
                cachedPrefixBytes,
                Self.commonPrefixCount(autocompletePromptBytes, promptBytes)
            )

            if confirmedCommonBytes > 0 {
                let commonTokenPrefix = Self.commonPrefixCount(autocompletePromptTokens, promptTokens)
                let reusableTokenCount = Self.reusableTokenCount(
                    commonTokenPrefix: commonTokenPrefix,
                    newPromptTokenCount: promptTokens.count
                )

                if reusableTokenCount > 0,
                   engine.trimKV(autocompleteSequenceID, Int32(reusableTokenCount)) {

                    let remaining = Array(promptTokens[reusableTokenCount...])
                    if !remaining.isEmpty {
                        // Seed for the reuse path is sampled at the end of this decodePrompt; apply
                        // the word-continuation constraint to it just like the fresh path does.
                        engine.setForceWordContinuation(autocompleteSequenceID, options.forceWordContinuation)
                        var mutableRemaining = remaining
                        let status = engine.decodePrompt(
                            autocompleteSequenceID,
                            &mutableRemaining,
                            Int32(mutableRemaining.count),
                            Int32(reusableTokenCount)
                        )
                        if status != .ok {
                            // Reuse failed mid-decode; fall through to fresh build.
                            engine.destroySequence(autocompleteSequenceID)
                            autocompleteSequenceID = -1
                            return try buildFreshSequence(promptTokens: promptTokens, options: options)
                        }
                    }
                    return autocompleteSequenceID
                }
            }
        }

        if autocompleteSequenceID >= 0 {
            engine.destroySequence(autocompleteSequenceID)
            autocompleteSequenceID = -1
        }
        return try buildFreshSequence(promptTokens: promptTokens, options: options)
    }

    private func buildFreshSequence(
        promptTokens: [Int32],
        options: LlamaGenerationOptions
    ) throws -> Int32 {
        let config = Self.samplingConfig(from: options)
        let seqID = engine.createSequence(config)
        guard seqID >= 0 else {
            throw LlamaRuntimeError.generationFailed("Unable to create inference sequence.")
        }

        // The engine samples the first (seed) token at the end of decodePrompt, so set the
        // word-continuation constraint here, before decoding.
        engine.setForceWordContinuation(seqID, options.forceWordContinuation)

        var tokens = promptTokens
        let status = engine.decodePrompt(seqID, &tokens, Int32(tokens.count), 0)
        guard status == .ok else {
            engine.destroySequence(seqID)
            throw LlamaRuntimeError.generationFailed("Prompt decoding failed.")
        }

        autocompleteSequenceID = seqID
        return seqID
    }

    // MARK: - Private: helpers

    private func tokenize(_ text: String) -> [Int32] {
        let utf8Count = text.utf8.count
        guard utf8Count > 0 else { return [] }
        let vec = engine.tokenize(text, Int32(utf8Count))
        return Array(vec)
    }

    private static func extractPiece(_ result: SampleResult) -> String {
        guard let piece = result.piece, result.piece_length > 0 else { return "" }
        let buffer = UnsafeBufferPointer(
            start: UnsafeRawPointer(piece).assumingMemoryBound(to: UInt8.self),
            count: Int(result.piece_length)
        )
        return String(bytes: buffer, encoding: .utf8) ?? ""
    }

    private static func samplingConfig(from options: LlamaGenerationOptions) -> SamplingConfig {
        SamplingConfig(
            max_prediction_tokens: Int32(options.maxPredictionTokens),
            temperature: Float(options.temperature),
            top_k: Int32(options.topK),
            top_p: Float(options.topP),
            min_p: Float(options.minP),
            repetition_penalty: Float(options.repetitionPenalty),
            seed: options.seed ?? 0,
            single_line: options.singleLine
        )
    }

    private static func reusableTokenCount(commonTokenPrefix: Int, newPromptTokenCount: Int) -> Int {
        guard newPromptTokenCount > 1 else { return 0 }
        return min(commonTokenPrefix, newPromptTokenCount - 1)
    }

    private static func commonPrefixCount<Element: Equatable>(_ lhs: [Element], _ rhs: [Element]) -> Int {
        var index = 0
        let limit = min(lhs.count, rhs.count)
        while index < limit, lhs[index] == rhs[index] {
            index += 1
        }
        return index
    }

    /// Generation knobs that intentionally break KV reuse when changed.
    private struct SamplingFingerprint: Equatable {
        let maxPredictionTokens: Int
        let temperature: Double
        let topK: Int
        let topP: Double
        let minP: Double
        let repetitionPenalty: Double
        let seed: UInt32?

        init(options: LlamaGenerationOptions) {
            maxPredictionTokens = options.maxPredictionTokens
            temperature = options.temperature
            topK = options.topK
            topP = options.topP
            minP = options.minP
            repetitionPenalty = options.repetitionPenalty
            seed = options.seed
        }
    }
}
