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

    /// The sequence the in-flight autocomplete operation is decoding into, published for
    /// `abortInFlightGeneration` to target from the canceller's thread. Guarded by its own lock
    /// because the abort fires while `autocompleteLock` is held by the very work being aborted.
    private let abortTargetLock = NSLock()
    private var abortTargetSequenceID: Int32 = -1

    /// One loud line per model load when the engine rejects partial KV trims (llama.cpp cannot
    /// drop mid-sequence ranges on hybrid/recurrent or SWA caches). Without this signal the
    /// prefix-reuse fast path degrades silently to a full prompt re-prefill on every request.
    private var loggedTrimRejectionForCurrentModel = false

    /// True once the loaded model has rejected a partial KV trim (hybrid/recurrent and SWA caches
    /// reject them unconditionally). On such models prefix reuse can never succeed, so prewarm
    /// prefills are pure double work: the warmed sequence cannot be trimmed back to prompt-only
    /// state, and the following generate's reuse trim is rejected too, forcing a second full
    /// decode of the same prompt. Guarded by `autocompleteLock`; reset on model load.
    private var modelRejectsPartialTrims = false

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
        loggedTrimRejectionForCurrentModel = false
        modelRejectsPartialTrims = false
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
        let preparation = try preparedPrompt(prompt: prompt, cachedPrefixBytes: cachedPrefixBytes, options: options, kind: "generate")

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

        autocompleteLock.lock()
        defer { autocompleteLock.unlock() }
        // Registered before `obtainAutocompleteSequence` because that call publishes the abort
        // target ahead of its prompt decode; every exit (including a cancelled prefill throwing)
        // must clear it so a late abort can never flag a recycled sequence slot.
        defer { clearAbortTarget() }

        let sequenceID = try obtainAutocompleteSequence(
            promptTokens: preparation.promptTokens,
            promptBytes: preparation.promptBytes,
            fingerprint: preparation.fingerprint,
            cachedPrefixBytes: preparation.cachedPrefixBytes,
            options: options
        )

        defer {
            // Trim sampled tokens so KV retains only the prompt for the next request. A rejected
            // trim leaves the sampled tokens in KV while the tracker records prompt-only state;
            // that mismatch self-heals (the next reuse trim is rejected too and rebuilds fresh),
            // but it also proves this model can never reuse, so remember that for `prefill`.
            if !engine.trimKV(sequenceID, Int32(preparation.promptTokens.count)) {
                modelRejectsPartialTrims = true
            }
            autocompletePromptBytes = preparation.promptBytes
            autocompletePromptTokens = preparation.promptTokens
            autocompleteSamplingFingerprint = preparation.fingerprint
        }

        // The KV-trim defer above runs after the decoder returns, restoring prompt-only KV state for
        // the next request. Token selection is delegated to the engine's built-in sampler.
        let decode = runEngineSampledDecode(sequenceID: sequenceID, options: options)
        if decode.engineCancelled {
            // The engine's per-sequence abort flag is set-once; an aborted sequence would refuse
            // every future decode, so drop it and let the next request build fresh.
            engine.destroySequence(sequenceID)
            autocompleteSequenceID = -1
        }
        return decode.text
    }

    /// Decodes `prompt` into the autocomplete KV cache without sampling, so the next `generate`
    /// whose prompt extends this one only pays for the typed delta. This is the llama half of
    /// prewarm-on-focus: a focus change destroys the previous field's sequence, and without a
    /// prefill the first suggestion in every field pays the full cold prompt decode.
    func prefill(
        prompt: String,
        cachedPrefixBytes: Int? = nil,
        options: LlamaGenerationOptions
    ) throws {
        let preparation = try preparedPrompt(prompt: prompt, cachedPrefixBytes: cachedPrefixBytes, options: options, kind: "prefill")

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

        autocompleteLock.lock()
        defer { autocompleteLock.unlock() }
        // Same exit guarantee as `generate`: see the comment there.
        defer { clearAbortTarget() }

        // On models that reject partial trims (the hybrid/SWA catalog families), a warmed
        // sequence can never be reused, so prefilling would only double the cold decode the
        // first real request pays anyway. The flag is learned from the first rejected trim
        // after model load; until then one speculative prefill may still run and be discarded.
        guard !modelRejectsPartialTrims else {
            CotabbyLogger.runtime.debug("Prefill skipped: the loaded model rejects partial KV trims")
            return
        }

        // A superseding generation cancels the warmup task before contending on the lock above.
        // The engine-level abort only reaches a decode that already published its target, so close
        // the window where the cancel landed while this prefill was still tokenizing or queued.
        guard !Task.isCancelled else {
            throw CancellationError()
        }

        let sequenceID = try obtainAutocompleteSequence(
            promptTokens: preparation.promptTokens,
            promptBytes: preparation.promptBytes,
            fingerprint: preparation.fingerprint,
            cachedPrefixBytes: preparation.cachedPrefixBytes,
            options: options
        )

        // `decodePrompt` samples one seed token beyond the prompt, so the trim is what restores
        // prompt-only KV. If it is rejected, the warmed sequence still carries the seed and can
        // never be trimmed by the following generate either: drop it instead of recording tracker
        // facts the KV does not match, and remember that warming this model is pointless.
        if engine.trimKV(sequenceID, Int32(preparation.promptTokens.count)) {
            autocompletePromptBytes = preparation.promptBytes
            autocompletePromptTokens = preparation.promptTokens
            autocompleteSamplingFingerprint = preparation.fingerprint
        } else {
            modelRejectsPartialTrims = true
            engine.destroySequence(sequenceID)
            autocompleteSequenceID = -1
            logTrimRejectionIfNeeded(reusableTokenCount: preparation.promptTokens.count)
        }
    }

    /// Aborts the in-flight autocomplete operation's native work mid-prefill. Task cancellation is
    /// only polled between sampled tokens, so without this an uninterruptible prompt decode makes
    /// the next request wait out the entire stale prefill. Safe from any thread: the engine flag
    /// is atomic and its sequence lookup is mutex-guarded; a no-op when nothing is in flight.
    func abortInFlightGeneration() {
        abortTargetLock.lock()
        let target = abortTargetSequenceID
        abortTargetLock.unlock()
        guard target >= 0 else {
            return
        }
        engine.cancelSequence(target)
    }

    private func setAbortTarget(_ sequenceID: Int32) {
        abortTargetLock.lock()
        abortTargetSequenceID = sequenceID
        abortTargetLock.unlock()
    }

    private func clearAbortTarget() {
        abortTargetLock.lock()
        abortTargetSequenceID = -1
        abortTargetLock.unlock()
    }

    /// Shared tokenize/truncate/log front half of `generate` and `prefill`.
    private func preparedPrompt(
        prompt: String,
        cachedPrefixBytes: Int?,
        options: LlamaGenerationOptions,
        kind: String
    ) throws -> PreparedPrompt {
        guard let preparedRuntime else {
            throw LlamaRuntimeError.unavailable("The llama model is not loaded.")
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
                "kind": .string(kind),
                "prompt_tokens": .stringConvertible(allPromptTokens.count),
                "max_tokens": .stringConvertible(options.maxPredictionTokens),
                "cached_prefix_bytes": .string(cachedPrefixBytes.map(String.init) ?? "none")
            ]
        )

        let maxPromptTokens = max(1, preparedRuntime.contextWindowTokens - options.maxPredictionTokens)
        if allPromptTokens.count > maxPromptTokens {
            return PreparedPrompt(
                promptBytes: promptBytes,
                promptTokens: Array(allPromptTokens.suffix(maxPromptTokens)),
                cachedPrefixBytes: nil,
                fingerprint: SamplingFingerprint(options: options)
            )
        }
        return PreparedPrompt(
            promptBytes: promptBytes,
            promptTokens: allPromptTokens,
            cachedPrefixBytes: cachedPrefixBytes,
            fingerprint: SamplingFingerprint(options: options)
        )
    }

    private struct PreparedPrompt {
        let promptBytes: [UInt8]
        let promptTokens: [Int32]
        let cachedPrefixBytes: Int?
        let fingerprint: SamplingFingerprint
    }

    // MARK: - Decoders

    /// The shipping decoder: delegates token selection to the engine's built-in sampler
    /// (`sampleNext`), which applies temperature / top-k / top-p / min-p and commits each token.
    /// `engineCancelled` reports that the native abort flag fired; the sequence must then be
    /// discarded because the flag is set-once for a sequence's lifetime.
    private func runEngineSampledDecode(
        sequenceID: Int32,
        options: LlamaGenerationOptions
    ) -> (text: String, engineCancelled: Bool) {
        var generatedText = ""
        var tokensGenerated = 0
        var sumLogprob = 0.0
        var stopReason = "budget_exhausted"
        var engineCancelled = false

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
                engineCancelled = true
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

            // Stop at the first natural sentence boundary instead of running the full token budget.
            // This keeps completions tight and is latency-positive (fewer tokens), and it adds no
            // per-token vocabulary work: it only inspects the text already accumulated. The
            // classifier ignores decimals, abbreviations, and list markers, so it will not truncate
            // "e.g." or "3.14" mid-thought.
            if DecodeStopPolicy.shouldStop(
                accumulated: generatedText,
                tokensGenerated: tokensGenerated,
                minimumTokens: options.sentenceStopMinimumTokens
            ) {
                stopReason = "sentence_boundary"
                break
            }
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
            return ("", engineCancelled)
        }
        return (generatedText, engineCancelled)
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

                if reusableTokenCount > 0 {
                    if engine.trimKV(autocompleteSequenceID, Int32(reusableTokenCount)) {
                        let remaining = Array(promptTokens[reusableTokenCount...])
                        if !remaining.isEmpty {
                            // Seed for the reuse path is sampled at the end of this decodePrompt;
                            // apply the word-continuation constraint to it like the fresh path does.
                            engine.setForceWordContinuation(
                                autocompleteSequenceID,
                                options.forceWordContinuation
                            )
                            // Per-token log-probabilities cost two O(vocab) passes each in the
                            // engine; only compute them when the confidence gate would actually
                            // read them. Re-assert per request: the floor is not part of the
                            // sampling fingerprint, so a reused sequence must not carry a stale flag.
                            engine.setComputeLogprob(
                                autocompleteSequenceID,
                                options.confidenceFloor > -.infinity
                            )
                            setAbortTarget(autocompleteSequenceID)
                            var mutableRemaining = remaining
                            let status = engine.decodePrompt(
                                autocompleteSequenceID,
                                &mutableRemaining,
                                Int32(mutableRemaining.count),
                                Int32(reusableTokenCount)
                            )
                            if status == .cancelled {
                                // The caller's request was superseded mid-prefill. Do NOT rebuild
                                // fresh here: that would decode the full stale prompt right after
                                // its cancellation. The aborted sequence is unusable (set-once
                                // flag, partially decoded KV), so drop it and surface the cancel.
                                engine.destroySequence(autocompleteSequenceID)
                                autocompleteSequenceID = -1
                                throw CancellationError()
                            }
                            if status != .ok {
                                // Reuse failed mid-decode; fall through to fresh build.
                                engine.destroySequence(autocompleteSequenceID)
                                autocompleteSequenceID = -1
                                return try buildFreshSequence(promptTokens: promptTokens, options: options)
                            }
                        }
                        CotabbyLogger.runtime.debug(
                            "KV prefix reused",
                            metadata: [
                                "reused_tokens": .stringConvertible(reusableTokenCount),
                                "decoded_delta_tokens": .stringConvertible(promptTokens.count - reusableTokenCount)
                            ]
                        )
                        return autocompleteSequenceID
                    }

                    logTrimRejectionIfNeeded(reusableTokenCount: reusableTokenCount)
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
        // Skip the engine's per-token log-probability work (two O(vocab) passes per token)
        // whenever confidence suppression is disabled — the shipping default — since the value
        // would be summed and then discarded.
        engine.setComputeLogprob(seqID, options.confidenceFloor > -.infinity)

        setAbortTarget(seqID)
        var tokens = promptTokens
        let status = engine.decodePrompt(seqID, &tokens, Int32(tokens.count), 0)
        guard status == .ok else {
            engine.destroySequence(seqID)
            if status == .cancelled {
                // Superseded mid-prefill; the abort exists precisely so the next request does not
                // wait out the rest of this decode. Quiet cancellation, no runtime error.
                throw CancellationError()
            }
            throw LlamaRuntimeError.generationFailed("Prompt decoding failed.")
        }

        autocompleteSequenceID = seqID
        return seqID
    }

    /// Surfaces "this model cannot reuse its prompt KV" once per model load at info level, then
    /// per-event at debug. llama.cpp rejects partial sequence removal on hybrid (recurrent) and
    /// SWA caches — which includes the current catalog families — and the silent fallback is a
    /// full prompt re-prefill on every keystroke pause: the difference between decoding a few
    /// delta tokens and the entire prompt.
    private func logTrimRejectionIfNeeded(reusableTokenCount: Int) {
        modelRejectsPartialTrims = true
        if !loggedTrimRejectionForCurrentModel {
            loggedTrimRejectionForCurrentModel = true
            CotabbyLogger.runtime.info(
                "KV prefix reuse unavailable: the engine rejected a partial trim, so every request re-decodes its full prompt",
                metadata: [
                    "model": .string(preparedRuntime?.resolvedRuntime.modelDisplayName ?? "unknown"),
                    "rejected_reusable_tokens": .stringConvertible(reusableTokenCount)
                ]
            )
            return
        }

        CotabbyLogger.runtime.debug(
            "KV prefix trim rejected; rebuilding sequence",
            metadata: ["rejected_reusable_tokens": .stringConvertible(reusableTokenCount)]
        )
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

    /// Fixed default sampler seed so suggestions are reproducible for the same context. The engine
    /// treats seed 0 as "reseed randomly per sequence", which made identical contexts produce
    /// different ghost text run to run; a stable nonzero seed removes that variance. Requests can
    /// still override via `LlamaGenerationOptions.seed` (used by tests and microbenches).
    private static let defaultSamplerSeed: UInt32 = 0x00C0_FFEE

    private static func samplingConfig(from options: LlamaGenerationOptions) -> SamplingConfig {
        SamplingConfig(
            max_prediction_tokens: Int32(options.maxPredictionTokens),
            temperature: Float(options.temperature),
            top_k: Int32(options.topK),
            top_p: Float(options.topP),
            min_p: Float(options.minP),
            repetition_penalty: Float(options.repetitionPenalty),
            seed: options.seed ?? Self.defaultSamplerSeed,
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
