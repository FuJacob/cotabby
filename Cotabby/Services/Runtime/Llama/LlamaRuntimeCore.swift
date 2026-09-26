import Foundation
import Logging
import CotabbyInference

/// File overview:
/// Owns the C++ inference engine and manages the autocomplete KV cache lifecycle. This is the
/// lowest-level runtime boundary in the app: it loads the GGUF model, owns Cotabby's single
/// autocomplete sequence, tokenizes prompts, samples continuations, and frees native resources on
/// shutdown.
///
/// The engine serializes its one mutable llama context internally. This class is `@unchecked
/// Sendable` rather than an `actor` so native work can execute away from MainActor.
/// `autocompleteLock` serializes autocomplete-specific KV-cache state, while a separate
/// `lifecycleCondition` prevents `shutdown()` from unloading the model during generation.

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
    /// Describes the last successfully decoded prompt, not the current end of native KV. Sampling
    /// may leave a generated tail after this prefix; obtainAutocompleteSequence must restore the
    /// validated shared prefix before decoding any new request, including a cancelled sequence.
    private var autocompletePromptBytes: [UInt8] = []
    private var autocompletePromptTokens: [Int32] = []
    private var autocompleteSamplingFingerprint: SamplingFingerprint?

    /// The sequence the in-flight autocomplete operation is decoding into, published for
    /// `abortInFlightGeneration` to target from the canceller's thread. Guarded by its own lock
    /// because the abort fires while `autocompleteLock` is held by the very work being aborted.
    private let abortTargetLock = NSLock()
    private var abortTargetSequenceID: Int32 = -1
    private var abortTargetOperationID: UUID?
    private var currentOperationID: UUID?

    /// A restoration miss describes one checkpoint/prefix, not a model family's permanent
    /// capability. Log the first miss prominently and keep trying later compatible prompts.
    private var loggedTrimRejectionForCurrentModel = false

    /// Coordinates model lifecycle with in-flight generation. `generate()` increments the active
    /// count on entry and decrements on exit. `shutdown()` sets the
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
    /// `onPartialRawText` receives the cumulative raw completion after each sampled token, on the
    /// calling (detached) thread, so the UI can render ghost text before the decode finishes.
    func generate(
        prompt: String,
        cachedPrefixBytes: Int? = nil,
        options: LlamaGenerationOptions,
        operationID: UUID = UUID(),
        onPartialRawText: ((String) -> Void)? = nil
    ) throws -> LlamaGenerationOutput {
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
        try Task.checkCancellation()
        currentOperationID = operationID
        defer { currentOperationID = nil }
        // Tokenization reads native vocabulary; lifecycle ownership must begin before that read
        // so shutdown cannot free the model while this request waits for the cache lock.
        let preparation = try preparedPrompt(prompt: prompt, cachedPrefixBytes: cachedPrefixBytes, options: options, kind: "generate")
        // Registered before `obtainAutocompleteSequence` because that call publishes the abort
        // target ahead of its prompt decode; every exit (including a cancelled prefill throwing)
        // must clear it so a late abort can never flag a recycled sequence slot.
        defer { clearAbortTarget() }

        let sequenceID = try obtainAutocompleteSequence(
            preparation: preparation,
            options: options
        )

        // Record only after the entire prompt decoded successfully. Leave generated tokens in
        // native memory until the next request reveals the exact shared prefix to restore. Eagerly
        // restoring this whole prompt would replay its tail now and a second time during reuse.
        // The exit defer closes this operation's abort target; successful restoration in obtain
        // rearms native cancellation before publishing the next operation's target.
        autocompletePromptBytes = preparation.promptBytes
        autocompletePromptTokens = preparation.promptTokens
        autocompleteSamplingFingerprint = preparation.fingerprint
        return runEngineSampledDecode(
            sequenceID: sequenceID,
            options: options,
            healingPrefix: preparation.healingPrefix,
            onPartialRawText: onPartialRawText
        )
    }

    /// Decodes `prompt` into the autocomplete KV cache without sampling, so the next `generate`
    /// whose prompt extends this one only pays for the typed delta. This is the llama half of
    /// prewarm-on-focus: a focus change destroys the previous field's sequence, and without a
    /// prefill the first suggestion in every field pays the full cold prompt decode.
    func prefill(
        prompt: String,
        cachedPrefixBytes: Int? = nil,
        options: LlamaGenerationOptions,
        operationID: UUID = UUID()
    ) throws {
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
        try Task.checkCancellation()
        currentOperationID = operationID
        defer { currentOperationID = nil }
        let preparation = try preparedPrompt(prompt: prompt, cachedPrefixBytes: cachedPrefixBytes, options: options, kind: "prefill")
        // Same exit guarantee as `generate`: see the comment there.
        defer { clearAbortTarget() }

        // A superseding generation cancels the warmup task before contending on the lock above.
        // The engine-level abort only reaches a decode that already published its target, so close
        // the window where the cancel landed while this prefill was still tokenizing or queued.
        guard !Task.isCancelled else {
            throw CancellationError()
        }

        let sequenceID = try obtainAutocompleteSequence(
            preparation: preparation,
            options: options
        )

        // The seed is sampled but not decoded; prefill already has prompt-only KV. Trimming
        // clears pending sampling and cancellation without requiring recurrent rollback.
        clearAbortTarget()
        if engine.trimKV(sequenceID, Int32(preparation.promptTokens.count)) {
            autocompletePromptBytes = preparation.promptBytes
            autocompletePromptTokens = preparation.promptTokens
            autocompleteSamplingFingerprint = preparation.fingerprint
        } else {
            discardAutocompleteSequence()
            logTrimRejectionIfNeeded(reusableTokenCount: preparation.promptTokens.count)
        }
    }

    /// Stops an operation between prompt batches or sampled tokens. The currently submitted
    /// native decode finishes; the next batch observes this flag instead of processing the rest
    /// of a stale prompt. Safe from any thread: the engine flag
    /// is atomic and its sequence lookup is mutex-guarded; a no-op when nothing is in flight.
    func abortInFlightGeneration(operationID: UUID) {
        abortTargetLock.lock()
        defer { abortTargetLock.unlock() }
        guard abortTargetOperationID == operationID, abortTargetSequenceID >= 0 else {
            return
        }
        engine.cancelSequence(abortTargetSequenceID)
    }

    private func setAbortTarget(_ sequenceID: Int32) {
        abortTargetLock.lock()
        abortTargetSequenceID = sequenceID
        abortTargetOperationID = currentOperationID
        // A cancellation can arrive during tokenization, before there is a native target. Close
        // that gap when publishing the target so stale work cannot enter an entire prompt decode.
        if Task.isCancelled { engine.cancelSequence(sequenceID) }
        abortTargetLock.unlock()
    }

    private func clearAbortTarget() {
        abortTargetLock.lock()
        abortTargetSequenceID = -1
        abortTargetOperationID = nil
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

        // Reconsider the entire bounded word fragment, not just its last vocabulary token.
        // The pure plan protects byte identity; native sampling enforces the resulting prefix.
        let healing = TokenHealingPlan(
            prompt: prompt, tokens: allPromptTokens, singleLine: options.singleLine,
            piece: { Array(engine.tokenPiece($0)) }
        )
        let tokens = healing.promptTokens
        let healingPrefix = healing.replayBytes
        // A byte-fallback vocabulary can replay at most one token per prefix byte. Reserve a
        // separate bounded allowance so healing cannot consume the user's output-token budget.
        let maxPromptTokens = max(1, preparedRuntime.contextWindowTokens
            - options.maxPredictionTokens - healingPrefix.count)
        let truncated = tokens.count > maxPromptTokens
        return PreparedPrompt(
            promptBytes: promptBytes,
            promptTokens: Array(tokens.suffix(maxPromptTokens)),
            cachedPrefixBytes: truncated ? nil : cachedPrefixBytes,
            healingPrefix: healingPrefix,
            fingerprint: SamplingFingerprint(options: options)
        )
    }

    private struct PreparedPrompt {
        let promptBytes: [UInt8]
        let promptTokens: [Int32]
        let cachedPrefixBytes: Int?
        let healingPrefix: [UInt8]
        let fingerprint: SamplingFingerprint
    }

    // MARK: - Decoders

    /// The shipping decoder: delegates token selection to the engine's built-in sampler
    /// (`sampleNext`), which applies temperature / top-k / top-p / min-p and commits each token.
    /// The next request restores or discards retained cache after cancellation. `onPartialRawText` receives
    /// cumulative raw completion after each sampled token, on the calling thread.
    private func runEngineSampledDecode(
        sequenceID: Int32,
        options: LlamaGenerationOptions,
        healingPrefix: [UInt8],
        onPartialRawText: ((String) -> Void)? = nil
    ) -> LlamaGenerationOutput {
        var generatedText = ""
        var tokensGenerated = 0
        var sumLogprob = 0.0
        var stopReason = "budget_exhausted"
        var buffer = TokenHealingBuffer(replayedPrefix: healingPrefix)
        var replayTokens = 0

        for _ in 0 ..< options.maxPredictionTokens + healingPrefix.count {
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
            // The raw distribution's most-likely token is end-of-generation: the model wants to
            // stop here even though the stochastic sampler drew something else. Finalize with the
            // text accumulated so far and discard the sampled-but-unwanted token; this is the
            // anti-rambling stop the sentence classifier cannot express (lists, fragments, code).
            if options.stopAtArgmaxEOG, result.argmax_is_eog {
                stopReason = "argmax_eog"
                break
            }

            let replayWasComplete = buffer.replayComplete
            let partial = buffer.append(tokenBytes: Self.extractPieceBytes(result))
            if buffer.hasReplayMismatch {
                generatedText = ""
                stopReason = "healing_prefix_mismatch"
                break
            }
            if !replayWasComplete && !buffer.hasVisibleBytes {
                replayTokens += 1
                continue
            }
            generatedText = buffer.text
            tokensGenerated += 1
            sumLogprob += Double(result.logprob)
            // Cumulative text, not the delta: consumers render whole partials, and cumulative
            // semantics make late or reordered deliveries harmless downstream.
            if let partial { onPartialRawText?(partial) }

            // Stop at the first natural sentence boundary, or as soon as the text contains a
            // chat-template stop marker, instead of running the full token budget. Both are
            // latency-positive (fewer tokens) and add no per-token vocabulary work: they only
            // inspect the text already accumulated. The boundary classifier ignores decimals,
            // abbreviations, and list markers, so it will not truncate "e.g." or "3.14"
            // mid-thought; the marker stop produces identical visible text because the
            // normalizer truncates at the first marker anyway.
            if let earlyStop = DecodeStopPolicy.verdict(
                accumulated: generatedText,
                tokensGenerated: tokensGenerated,
                minimumTokens: options.sentenceStopMinimumTokens
            ) {
                stopReason = earlyStop.rawValue
                break
            }
            if tokensGenerated >= options.maxPredictionTokens { break }
        }

        CotabbyLogger.runtime.debug(
            "Decode end",
            metadata: [
                "kind": .string("generate"),
                "tokens_generated": .stringConvertible(tokensGenerated),
                "replay_tokens": .stringConvertible(replayTokens),
                "chars_generated": .stringConvertible(generatedText.count),
                "stop_reason": .string(stopReason)
            ]
        )

        return Self.generationOutput(text: generatedText, sumLogprob: sumLogprob, tokensGenerated: tokensGenerated, options: options)
    }

    /// Confidence affects the returned value after decode; it must not change retained KV state.
    private static func generationOutput(
        text generatedText: String,
        sumLogprob: Double,
        tokensGenerated: Int,
        options: LlamaGenerationOptions
    ) -> LlamaGenerationOutput {
        // The average is only meaningful when the engine actually computed per-token logprobs,
        // which is keyed on the floor being enabled (see setComputeLogprob at sequence setup).
        let averageLogprob: Double? = options.confidenceFloor > -.infinity && tokensGenerated > 0
            ? sumLogprob / Double(tokensGenerated)
            : nil
        if Self.shouldSuppress(sumLogprob: sumLogprob, tokensGenerated: tokensGenerated, options: options) {
            let suppressed = LlamaGenerationOutput(
                text: "",
                averageLogprob: averageLogprob,
                suppressedByLowConfidence: true
            )
            return suppressed
        }
        let output = LlamaGenerationOutput(
            text: generatedText,
            averageLogprob: averageLogprob,
            suppressedByLowConfidence: false
        )
        return output
    }

    /// Low-confidence gate for the sampled decoder: drop completions the model itself was unsure
    /// about. Disabled by default (confidenceFloor == -infinity). Suppressed output leaves the
    /// same retained native tail as visible output; the next request must restore its own prefix.
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

        discardAutocompleteSequence()
    }

    /// Called with autocompleteLock held. Clearing both native memory and its prompt description
    /// together prevents failed restoration from masquerading as a reusable prefix on the next run.
    private func discardAutocompleteSequence() {
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

    /// Waits for all in-flight `generate()` calls to finish, then frees all
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

    /// Returns a sequence ID with KV state representing the new prompt. The existing sequence may
    /// retain generated tokens or a cancellation flag; restoration is mandatory before reuse,
    /// even when both prompt descriptions are identical. A missed checkpoint rebuilds cold.
    /// Must be called while holding `autocompleteLock`.
    private func obtainAutocompleteSequence(
        preparation: PreparedPrompt,
        options: LlamaGenerationOptions
    ) throws -> Int32 {
        let promptTokens = preparation.promptTokens
        let promptBytes = preparation.promptBytes
        let fingerprint = preparation.fingerprint
        let cachedPrefixBytes = preparation.cachedPrefixBytes
        let healingPrefix = preparation.healingPrefix
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
                        logCacheRestoration(sequenceID: autocompleteSequenceID)
                        let remaining = Array(promptTokens[reusableTokenCount...])
                        if !remaining.isEmpty {
                            // Seed for the reuse path is sampled at the end of this decodePrompt;
                            // apply the word-continuation constraint to it like the fresh path does.
                            engine.setForceWordContinuation(
                                autocompleteSequenceID,
                                healingPrefix.isEmpty && options.forceWordContinuation
                            )
                            setCompletionPrefix(healingPrefix, sequenceID: autocompleteSequenceID)
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
                                // The caller's request was superseded between prompt batches. Do NOT rebuild
                                // fresh here: that would decode the full stale prompt right after
                                // its cancellation. A partially decoded new prompt has no matching
                                // Swift description yet, so discard it and surface cancellation.
                                engine.destroySequence(autocompleteSequenceID)
                                autocompleteSequenceID = -1
                                throw CancellationError()
                            }
                            if status != .ok {
                                // Reuse failed mid-decode; fall through to fresh build.
                                engine.destroySequence(autocompleteSequenceID)
                                autocompleteSequenceID = -1
                                return try buildFreshSequence(promptTokens: promptTokens, healingPrefix: healingPrefix, options: options)
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
        return try buildFreshSequence(promptTokens: promptTokens, healingPrefix: healingPrefix, options: options)
    }

    private func buildFreshSequence(
        promptTokens: [Int32],
        healingPrefix: [UInt8],
        options: LlamaGenerationOptions
    ) throws -> Int32 {
        let config = Self.samplingConfig(from: options)
        let seqID = engine.createSequence(config)
        guard seqID >= 0 else {
            throw LlamaRuntimeError.generationFailed("Unable to create inference sequence.")
        }

        // The engine samples the first (seed) token at the end of decodePrompt, so set the
        // word-continuation constraint here, before decoding.
        engine.setForceWordContinuation(seqID, healingPrefix.isEmpty && options.forceWordContinuation)
        setCompletionPrefix(healingPrefix, sequenceID: seqID)
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
                // Superseded between prompt batches; skip the remaining stale prompt so a new
                // request can acquire the lock. Quiet cancellation, no runtime error.
                throw CancellationError()
            }
            throw LlamaRuntimeError.generationFailed("Prompt decoding failed.")
        }

        autocompleteSequenceID = seqID
        return seqID
    }

    /// Records a cold fallback without permanently disabling prefill. A checkpoint is bounded:
    /// editing before it can miss even when ordinary typing reuses the same model successfully.
    private func logTrimRejectionIfNeeded(reusableTokenCount: Int) {
        if !loggedTrimRejectionForCurrentModel {
            loggedTrimRejectionForCurrentModel = true
            CotabbyLogger.runtime.info(
                "Prompt cache restoration missed; rebuilding this request",
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

    private func logCacheRestoration(sequenceID: Int32) {
        let cache = engine.getCacheDiagnostics(sequenceID)
        CotabbyLogger.runtime.debug(
            "Prompt cache restored",
            metadata: [
                "reused_tokens": .stringConvertible(cache.decoded_token_count),
                "checkpoint_bytes": .stringConvertible(cache.checkpoint_bytes),
                "checkpoint_position": .stringConvertible(cache.checkpoint_position),
                "restore_replayed_tokens": .stringConvertible(cache.last_restore_replayed_tokens),
                "partial_state_checkpoint": .stringConvertible(cache.uses_partial_checkpoint)
            ]
        )
    }

    // MARK: - Private: helpers

    private func tokenize(_ text: String) -> [Int32] {
        let utf8Count = text.utf8.count
        guard utf8Count > 0 else { return [] }
        let vec = engine.tokenize(text, Int32(utf8Count))
        return Array(vec)
    }

    private func setCompletionPrefix(_ bytes: [UInt8], sequenceID: Int32) {
        bytes.withUnsafeBufferPointer { buffer in
            engine.setCompletionPrefix(sequenceID, buffer.baseAddress, Int32(buffer.count))
        }
    }

    private static func extractPieceBytes(_ result: SampleResult) -> [UInt8] {
        guard let piece = result.piece, result.piece_length > 0 else { return [] }
        let buffer = UnsafeBufferPointer(
            start: UnsafeRawPointer(piece).assumingMemoryBound(to: UInt8.self),
            count: Int(result.piece_length)
        )
        return Array(buffer)
    }

    /// Fixed default sampler seed so suggestions are reproducible for the same context. The engine
    /// treats seed 0 as "reseed randomly per sequence", which made identical contexts produce
    /// different ghost text run to run; a stable nonzero seed removes that variance. Requests can
    /// still override via `LlamaGenerationOptions.seed` (used by tests and microbenches).
    private static let defaultSamplerSeed: UInt32 = 0x00C0_FFEE

    private static func samplingConfig(from options: LlamaGenerationOptions) -> SamplingConfig {
        // Assign the fields after default construction so the app remains source-compatible while
        // CotabbyInference removes native configuration fields that Swift never consumed. C++
        // aggregate memberwise initializers otherwise require every imported field at the call site.
        var config = SamplingConfig()
        config.temperature = Float(options.temperature)
        config.top_k = Int32(options.topK)
        config.top_p = Float(options.topP)
        config.min_p = Float(options.minP)
        config.repetition_penalty = Float(options.repetitionPenalty)
        config.seed = options.seed ?? Self.defaultSamplerSeed
        config.single_line = options.singleLine
        return config
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
        let singleLine: Bool

        init(options: LlamaGenerationOptions) {
            maxPredictionTokens = options.maxPredictionTokens
            temperature = options.temperature
            topK = options.topK
            topP = options.topP
            minP = options.minP
            repetitionPenalty = options.repetitionPenalty
            seed = options.seed
            singleLine = options.singleLine
        }
    }
}
