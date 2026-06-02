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

    /// Per-model constrained-decoding token table, built lazily on the first constrained request and
    /// reused across requests. Keyed by model URL so loading a different model rebuilds it. Read and
    /// written only inside `runConstrainedDecode`, which runs under `autocompleteLock`, so it needs
    /// no extra synchronization. Cleared on `shutdown()` to release the table when the model unloads.
    private var cachedTokenProfile: TokenProfile?
    private var cachedTokenProfileModelURL: URL?

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
        let promptTokens: [Int32]
        let adjustedCachedPrefixBytes: Int?
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

        // The KV-trim defer above runs after whichever decoder returns. Both decoders share the
        // prepared sequence and the same confidence-suppression contract; they differ only in how
        // they pick each token (engine sampler vs. deterministic constrained selection).
        guard options.useConstrainedDecoder else {
            return runEngineSampledDecode(sequenceID: sequenceID, options: options)
        }
        return options.beamWidth > 1
            ? try runConstrainedBeamDecode(
                sequenceID: sequenceID,
                promptTokenCount: promptTokens.count,
                options: options
            )
            : try runConstrainedDecode(sequenceID: sequenceID, options: options)
    }

    // MARK: - Decoders

    /// No-repeat-ngram order for the constrained decoder: forbid re-emitting any 3-gram already in the
    /// output. 3 is the conventional choice — it breaks phrase loops ("I think that I think that") and
    /// single-token runs after a few repeats, without blocking ordinary short repeats like "very very".
    private static let noRepeatNgramSize = 3

    /// ASCII sentence terminators (`.` `!` `?`), used as a cheap pre-filter: the constrained decoder
    /// only decodes the accumulated bytes to test for a sentence boundary when a token carried one of
    /// these, keeping the steady path on raw byte accumulation.
    private static func isSentenceTerminatorByte(_ byte: UInt8) -> Bool {
        byte == 0x2E || byte == 0x21 || byte == 0x3F
    }

    /// The stop reason for a token that must end the loop *before* it is committed to the output: an
    /// end-of-generation token, or a line break in a single-line field. Returns nil to commit the
    /// token. Folding both checks into one helper keeps the decode loop under the complexity budget.
    private static func preCommitStopReason(
        tokenID: Int,
        options: LlamaGenerationOptions,
        profile: TokenProfile
    ) -> String? {
        if profile.isEndOfGeneration(tokenID) {
            return "eos"
        }
        if options.singleLine, profile.isNewline(tokenID) {
            return "single_line"
        }
        return nil
    }

    /// Whether the accumulated completion bytes now end a sentence. Decodes only when the last token
    /// carried an ASCII sentence terminator, so the steady decode path avoids per-token String work.
    /// Kept as a helper so the decode loop stays under the cyclomatic-complexity budget.
    private static func completesSentence(_ generatedBytes: [UInt8], lastTokenBytes: [UInt8]) -> Bool {
        guard lastTokenBytes.contains(where: isSentenceTerminatorByte) else {
            return false
        }
        // swiftlint:disable:next optional_data_string_conversion
        let decoded = String(decoding: generatedBytes, as: UTF8.self)
        return SentenceBoundaryClassifier.endsSentence(decoded)
    }

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

    /// The constrained decoder: reads the raw next-token logits, masks structural / excluded tokens
    /// via the token profile, deterministically selects the highest-logit admissible token, and
    /// commits it manually with `acceptToken`. This trades the sampler's randomness for reproducible,
    /// leak-free continuations (no chat/control markers can surface as visible text). It honors the
    /// same cancellation, single-line, and confidence-suppression contracts as the sampled path.
    /// Mid-word word-continuation is already applied to the seed logits by `decodePrompt` (the engine
    /// masks new-word-start tokens for the first step), so the first `getNextTokenLogits` row this
    /// reads is already constrained when `forceWordContinuation` was set.
    private func runConstrainedDecode(sequenceID: Int32, options: LlamaGenerationOptions) throws -> String {
        let profile = try autocompleteTokenProfile()
        let vocabSize = profile.vocabSize
        guard vocabSize > 0 else {
            throw LlamaRuntimeError.generationFailed("Vocabulary unavailable for constrained decoding.")
        }
        // `topK` bounds the candidate pool the selector ranks; clamp to a sane positive value so a
        // zero/negative request still yields a full-vocab argmax rather than an empty pool.
        let topK = options.topK > 0 ? options.topK : vocabSize

        var generatedBytes: [UInt8] = []
        // Token-id history feeds the no-repeat-ngram guard; tracked separately from bytes because the
        // guard reasons over token ids, not decoded text.
        var generatedTokenIDs: [Int] = []
        var tokensGenerated = 0
        var sumLogprob = 0.0
        var stopReason = "budget_exhausted"
        var logits = [Float](repeating: 0, count: vocabSize)

        for _ in 0 ..< options.maxPredictionTokens {
            if Task.isCancelled {
                stopReason = "cancelled"
                break
            }

            let written = logits.withUnsafeMutableBufferPointer { buffer in
                Int(engine.getNextTokenLogits(sequenceID, buffer.baseAddress, Int32(buffer.count)))
            }
            guard written == vocabSize else {
                stopReason = "no_logits"
                break
            }

            // Block any token that would close an n-gram already emitted, so greedy argmax cannot fall
            // into a repetition loop (the engine's repetition penalty does not reach this raw-logit path).
            let blockedTokenIDs = RepetitionGuard.blockedTokens(
                history: generatedTokenIDs,
                ngramSize: Self.noRepeatNgramSize
            )
            guard let tokenID = ConstrainedSampler.selectToken(
                logits: logits,
                profile: profile,
                admissibleTokenIDs: nil,
                topK: topK,
                blockedTokenIDs: blockedTokenIDs
            ) else {
                stopReason = "no_admissible_token"
                break
            }

            // A token can stop the loop before it is committed: an end-of-generation token, or a line
            // break in a single-line field (the partial completion so far is preserved).
            if let preCommitStop = Self.preCommitStopReason(tokenID: tokenID, options: options, profile: profile) {
                stopReason = preCommitStop
                break
            }

            // Accumulate raw bytes and decode once at the end: a single token may carry only part of
            // a multi-byte UTF-8 scalar, so per-token String decoding would corrupt CJK / emoji.
            let tokenBytes = profile.bytes(for: tokenID)
            if let logProb = ConstrainedSampler.logProb(ofTokenAt: tokenID, in: logits) {
                sumLogprob += logProb
            }
            generatedBytes.append(contentsOf: tokenBytes)
            generatedTokenIDs.append(tokenID)
            tokensGenerated += 1

            if engine.acceptToken(sequenceID, Int32(tokenID)) != .ok {
                stopReason = "accept_failed"
                break
            }

            // Stop cleanly at the end of a sentence rather than running into the next one.
            if Self.completesSentence(generatedBytes, lastTokenBytes: tokenBytes) {
                stopReason = "sentence_boundary"
                break
            }
        }

        // Lossy decode is deliberate: the accumulated bytes are valid UTF-8 except for a possible
        // partial trailing scalar (the final token may carry only part of a multi-byte character).
        // The failable `String(bytes:encoding:)` would discard the entire completion in that case;
        // `String(decoding:)` keeps every complete scalar and renders only the fragment as U+FFFD.
        // swiftlint:disable:next optional_data_string_conversion
        let generatedText = String(decoding: generatedBytes, as: UTF8.self)
        CotabbyLogger.runtime.debug(
            "Decode end",
            metadata: [
                "kind": .string("generate_constrained"),
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

    /// Multi-branch (beam) variant of the constrained decoder. Explores several short continuations
    /// over the shared sequence — `EngineBeamStepper` syncs the KV cache to each branch's token path —
    /// and returns the highest-scoring one. Reuses the same token profile, no-repeat-ngram guard,
    /// sentence-boundary stop, and confidence suppression as the greedy path. The caller's KV-trim
    /// defer restores the prompt-only state afterward.
    private func runConstrainedBeamDecode(
        sequenceID: Int32,
        promptTokenCount: Int,
        options: LlamaGenerationOptions
    ) throws -> String {
        let profile = try autocompleteTokenProfile()
        let vocabSize = profile.vocabSize
        guard vocabSize > 0 else {
            throw LlamaRuntimeError.generationFailed("Vocabulary unavailable for constrained decoding.")
        }
        let topK = options.topK > 0 ? options.topK : vocabSize
        var currentPath: [Int] = []
        var logitsBuffer = [Float](repeating: 0, count: vocabSize)
        let candidates = ConstrainedBeamSearch.search(
            nextLogits: { generatedTokens in
                self.beamLogits(
                    forGeneratedTokens: generatedTokens,
                    sequenceID: sequenceID,
                    promptTokenCount: promptTokenCount,
                    currentPath: &currentPath,
                    logitsBuffer: &logitsBuffer
                )
            },
            profile: profile,
            configuration: BeamSearchConfiguration(
                beamWidth: options.beamWidth,
                maxTokens: options.maxPredictionTokens,
                topK: topK,
                noRepeatNgramSize: Self.noRepeatNgramSize
            ),
            isSingleLine: options.singleLine
        )
        let best = candidates.first
        CotabbyLogger.runtime.debug(
            "Decode end",
            metadata: [
                "kind": .string("generate_beam"),
                "beam_width": .stringConvertible(options.beamWidth),
                "candidates": .stringConvertible(candidates.count),
                "tokens_generated": .stringConvertible(best?.tokenIDs.count ?? 0)
            ]
        )
        guard let best else {
            return ""
        }
        if Self.shouldSuppress(
            sumLogprob: best.cumulativeLogprob,
            tokensGenerated: best.tokenIDs.count,
            options: options
        ) {
            return ""
        }
        return best.text
    }

    /// Beam-search logits provider: syncs the shared sequence's KV to `generatedTokens`, then reads
    /// the next-token logits. `currentPath` / `logitsBuffer` are owned by one beam run (the caller),
    /// so this stays a plain method on the runtime where `engine` (a noncopyable C++ value) is mutable.
    private func beamLogits(
        forGeneratedTokens generatedTokens: [Int],
        sequenceID: Int32,
        promptTokenCount: Int,
        currentPath: inout [Int],
        logitsBuffer: inout [Float]
    ) -> [Float]? {
        guard syncBeamSequence(
            to: generatedTokens,
            sequenceID: sequenceID,
            promptTokenCount: promptTokenCount,
            currentPath: &currentPath
        ) else {
            return nil
        }
        let vocabSize = logitsBuffer.count
        let written = logitsBuffer.withUnsafeMutableBufferPointer { buffer in
            Int(engine.getNextTokenLogits(sequenceID, buffer.baseAddress, Int32(buffer.count)))
        }
        guard written == vocabSize else {
            return nil
        }
        return logitsBuffer
    }

    /// Brings the sequence KV to exactly `target` tokens beyond the prompt: trim back to the longest
    /// shared prefix with the current path, then accept the remaining target tokens. `currentPath` is
    /// updated as tokens are accepted so it always reflects the real KV length, even on a mid-accept
    /// failure (the caller treats a false return as "this branch cannot be extended").
    private func syncBeamSequence(
        to target: [Int],
        sequenceID: Int32,
        promptTokenCount: Int,
        currentPath: inout [Int]
    ) -> Bool {
        let shared = Self.commonPrefixLength(currentPath, target)
        if currentPath.count > shared, !engine.trimKV(sequenceID, Int32(promptTokenCount + shared)) {
            currentPath = []
            return false
        }
        currentPath = Array(target[..<shared])
        for index in shared ..< target.count {
            guard engine.acceptToken(sequenceID, Int32(target[index])) == .ok else {
                return false
            }
            currentPath.append(target[index])
        }
        return true
    }

    private static func commonPrefixLength(_ lhs: [Int], _ rhs: [Int]) -> Int {
        var count = 0
        let limit = min(lhs.count, rhs.count)
        while count < limit, lhs[count] == rhs[count] {
            count += 1
        }
        return count
    }

    /// Shared low-confidence gate for both decoders: drop completions the model itself was unsure
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
        cachedTokenProfile = nil
        cachedTokenProfileModelURL = nil
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

    /// Lazily builds and caches the constrained-decoding token profile for the loaded model. The
    /// profile records each token's bytes and structural flags so the constrained decoder can mask
    /// excluded tokens and detect stops without calling back into the engine per step. Building scans
    /// the whole vocabulary once (one detokenize per token), so the result is cached and reused until
    /// the model changes. Must be called while holding `autocompleteLock`.
    private func autocompleteTokenProfile() throws -> TokenProfile {
        let modelURL = preparedRuntime?.resolvedRuntime.modelFileURL
        if let cachedTokenProfile, cachedTokenProfileModelURL == modelURL {
            return cachedTokenProfile
        }

        let vocabSize = Int(engine.getVocabSize())
        guard vocabSize > 0 else {
            throw LlamaRuntimeError.generationFailed("Vocabulary unavailable for constrained decoding.")
        }

        // Detokenize every token once up front; the build closures index this snapshot so each
        // token's bytes are computed a single time and its control flag derives from the same bytes.
        var tokenBytes: [[UInt8]] = []
        tokenBytes.reserveCapacity(vocabSize)
        for id in 0 ..< vocabSize {
            tokenBytes.append(detokenizeBytes(Int32(id)))
        }

        let profile = TokenProfile.build(
            vocabSize: vocabSize,
            bytesFor: { tokenBytes[$0] },
            // A token that detokenizes to no visible bytes is a structural / special / control token
            // (llama renders those empty when special rendering is off); never emit it as text.
            isControl: { tokenBytes[$0].isEmpty },
            isEndOfGeneration: { self.engine.isEndOfGenerationToken(Int32($0)) }
        )
        cachedTokenProfile = profile
        cachedTokenProfileModelURL = modelURL
        CotabbyLogger.runtime.debug(
            "Built constrained-decode token profile",
            metadata: ["vocab_size": .stringConvertible(vocabSize)]
        )
        return profile
    }

    /// The raw UTF-8 bytes a token detokenizes to, or empty for a structural token that renders to
    /// nothing. `detokenize` returns the byte count, or a negative `-(required)` when the fixed
    /// buffer is too small; the rare large-piece case retries once at the requested size.
    private func detokenizeBytes(_ token: Int32) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 256)
        let written = buffer.withUnsafeMutableBufferPointer { ptr in
            Int(engine.detokenize(token, ptr.baseAddress, Int32(ptr.count)))
        }
        if written > 0 {
            return buffer.prefix(written).map { UInt8(bitPattern: $0) }
        }
        if written < 0 {
            var large = [CChar](repeating: 0, count: -written)
            let writtenLarge = large.withUnsafeMutableBufferPointer { ptr in
                Int(engine.detokenize(token, ptr.baseAddress, Int32(ptr.count)))
            }
            return writtenLarge > 0 ? large.prefix(writtenLarge).map { UInt8(bitPattern: $0) } : []
        }
        return []
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
