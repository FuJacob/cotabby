import Foundation
import LlamaSwift
import os

/// File overview:
/// Owns the raw llama.cpp lifecycle behind one serialized actor. This file is the lowest-level
/// runtime boundary in the app: it loads the GGUF model, maintains a reusable prompt context,
/// tokenizes prompts, samples continuations, and frees native resources on shutdown.
///
/// Keeping this work out of `LlamaRuntimeManager` makes the architecture easier to reason about:
/// the manager owns UI-facing state and selection flow, while this actor owns correctness around
/// mutable native pointers that must never be touched concurrently.
nonisolated private let llamaSilencedLogCallback: ggml_log_callback = { _, _, _ in }

/// Immutable runtime metadata captured after a model has been successfully prepared.
///
/// This is intentionally a separate type instead of a tuple so the manager can republish runtime
/// diagnostics by name, which is easier for a new maintainer to follow than positional values.
struct PreparedLlamaRuntime: Sendable {
    let resolvedRuntime: ResolvedLlamaRuntime
    let contextWindowTokens: Int
    let batchSize: Int
    let threadCount: Int
    let gpuLayerCount: Int
    let backendName: String
}

/// Owns the long-lived model and hides the raw llama.cpp lifecycle behind one serialized actor.
/// The actor owns one reusable prompt context so consecutive autocomplete requests can reuse the
/// already-decoded KV cache for their common token prefix. Keeping that state here matters because
/// raw llama pointers are mutable and must be serialized behind one owner.
actor LlamaRuntimeCore {
    private static var isNativeLoggingSilenced = false
    private static let promptSequenceID: llama_seq_id = 0

    /// Filterable signal for first-token gating activity. Visible via:
    ///   log stream --predicate 'subsystem == "app.tabby" AND category == "first-token-gate"'
    /// Use `.debug` so production builds don't pay the cost unless someone explicitly streams it.
    private static let firstTokenGateLogger = Logger(
        subsystem: "app.tabby",
        category: "first-token-gate"
    )

    /// Filterable signal for first-token confidence-based suppression. Distinct category from the
    /// gate logger because these are *separate signals*: gating masks specific tokens; confidence
    /// suppression aborts the whole suggestion when the model's distribution at position 0 is too
    /// flat. A single generation can fire neither, one, or both.
    ///   log stream --predicate 'subsystem == "app.tabby" AND category == "first-token-confidence"'
    private static let firstTokenConfidenceLogger = Logger(
        subsystem: "app.tabby",
        category: "first-token-confidence"
    )

    private var backendInitialized = false
    private var model: OpaquePointer?
    private var preparedRuntime: PreparedLlamaRuntime?
    private var promptCache: PromptCache?

    /// Token IDs resolved from `FirstTokenDenyList` for the currently loaded model.
    /// These are computed once per model load in `prepare()` because tokenization requires the
    /// model's vocabulary. The list is intentionally small (typically <20 token IDs) so the
    /// logit-bias sampler adds negligible overhead.
    private var resolvedFirstTokenDenyList: [llama_logit_bias] = []

    /// Native prompt-cache state tied to one llama context.
    /// `promptTokens` records the tokens represented in KV memory; each new request still
    /// tokenizes and compares against this array because byte-prefix equality alone is not enough
    /// to prove tokenizer-boundary safety.
    private struct PromptCache {
        let context: OpaquePointer
        var promptBytes: [UInt8]
        var promptTokens: [llama_token]
        var samplingFingerprint: SamplingFingerprint
    }

    /// Generation knobs that intentionally break KV reuse when changed.
    /// The prompt KV itself is mostly independent from the sampler, but the product contract for
    /// this optimization is stricter: a different sampling configuration starts a clean context.
    private struct SamplingFingerprint: Equatable {
        let maxPredictionTokens: Int
        let temperature: Double
        let topK: Int
        let topP: Double
        let minP: Double
        let repetitionPenalty: Double
        let seed: UInt32?
    }

    /// Loads the requested model once and records the runtime characteristics needed for diagnostics.
    func prepare(
        resolvedRuntime: ResolvedLlamaRuntime,
        configuration: LlamaRuntimeConfiguration
    ) throws -> PreparedLlamaRuntime {
        if let preparedRuntime,
           preparedRuntime.resolvedRuntime.modelFileURL == resolvedRuntime.modelFileURL
        {
            return preparedRuntime
        }

        if preparedRuntime != nil {
            shutdown()
        }

        if !backendInitialized {
            if !Self.isNativeLoggingSilenced {
                llama_log_set(llamaSilencedLogCallback, nil)
                Self.isNativeLoggingSilenced = true
            }
            llama_backend_init()
            backendInitialized = true
        }

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = configuration.gpuLayerCount
        modelParams.use_mmap = true
        modelParams.use_mlock = false

        guard let loadedModel = resolvedRuntime.modelFileURL.path.withCString({
            llama_model_load_from_file($0, modelParams)
        }) else {
            throw LlamaRuntimeError.unavailable("Unable to load \(resolvedRuntime.modelDisplayName) with llama.cpp.")
        }

        model = loadedModel

        // Resolve the first-token deny list now that we have a loaded vocabulary.
        // This turns human-readable strings ("Sure", "Here", "I ") into concrete token IDs
        // that the logit-bias sampler can mask at `-inf` during generation.
        let modelFilename = resolvedRuntime.modelFileURL.lastPathComponent
        resolvedFirstTokenDenyList = resolveFirstTokenDenyList(
            for: modelFilename,
            model: loadedModel
        )

        // Log the resolved deny list so debug builds can verify which token IDs
        // got masked for this model. Useful when a chat opener still slips
        // through and you need to confirm whether it was on the list at all
        // versus the tokenizer producing a different leading token.
        if let vocab = llama_model_get_vocab(loadedModel) {
            let resolvedSummaries: [String] = resolvedFirstTokenDenyList.map { bias in
                let piece = pieceString(for: bias.token, vocab: vocab)
                let escaped = piece
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\t", with: "\\t")
                return "\(bias.token):\"\(escaped)\""
            }
            Self.firstTokenGateLogger.debug(
                "resolved deny list for \(modelFilename, privacy: .public): [\(resolvedSummaries.joined(separator: ", "), privacy: .public)]"
            )
        }

        let preparedRuntime = PreparedLlamaRuntime(
            resolvedRuntime: resolvedRuntime,
            contextWindowTokens: Int(configuration.contextWindowTokens),
            batchSize: Int(configuration.batchSize),
            threadCount: max(1, ProcessInfo.processInfo.activeProcessorCount),
            gpuLayerCount: Int(configuration.gpuLayerCount),
            backendName: "llama.swift (llama.cpp in-process)"
        )
        self.preparedRuntime = preparedRuntime
        return preparedRuntime
    }

    /// Prepares the prompt context, reusing cached KV state when safe, then samples a short completion.
    func generate(
        prompt: String,
        cachedPrefixBytes: Int? = nil,
        maxPredictionTokens: Int,
        temperature: Double,
        topK: Int,
        topP: Double,
        minP: Double,
        repetitionPenalty: Double,
        seed: UInt32? = nil,
        firstTokenGatingEnabled: Bool = true,
        firstTokenConfidenceGatingEnabled: Bool = false,
        firstTokenConfidenceThreshold: Double = 0.0
    ) throws -> String {
        guard let preparedRuntime else {
            throw LlamaRuntimeError.unavailable("The llama model is not loaded.")
        }

        guard let model else {
            throw LlamaRuntimeError.unavailable("The llama model is not loaded.")
        }

        guard let vocab = llama_model_get_vocab(model) else {
            throw LlamaRuntimeError.generationFailed("Unable to access the model vocabulary.")
        }

        let promptTokens = try tokenize(prompt, vocab: vocab)
        let samplingFingerprint = SamplingFingerprint(
            maxPredictionTokens: maxPredictionTokens,
            temperature: temperature,
            topK: topK,
            topP: topP,
            minP: minP,
            repetitionPenalty: repetitionPenalty,
            seed: seed
        )
        let promptBytes = Array(prompt.utf8)
        let context = try preparePromptContext(
            model: model,
            preparedRuntime: preparedRuntime,
            promptBytes: promptBytes,
            promptTokens: promptTokens,
            samplingFingerprint: samplingFingerprint,
            cachedPrefixBytes: cachedPrefixBytes
        )

        let sampler = try makeSampler(
            temperature: temperature,
            topK: topK,
            topP: topP,
            minP: minP,
            repetitionPenalty: repetitionPenalty,
            seed: seed
        )
        defer { llama_sampler_free(sampler) }

        // Build a separate sampler with the first-token logit gate prepended.
        // We use two samplers instead of mutating one mid-generation because it's more legible
        // and the cost of initializing a second chain is negligible next to model decode.
        let useFirstTokenGating = firstTokenGatingEnabled && !resolvedFirstTokenDenyList.isEmpty
        let firstTokenSampler: UnsafeMutablePointer<llama_sampler>?
        if useFirstTokenGating {
            firstTokenSampler = try makeFirstTokenGatedSampler(
                vocab: vocab,
                temperature: temperature,
                topK: topK,
                topP: topP,
                minP: minP,
                repetitionPenalty: repetitionPenalty,
                seed: seed
            )
        } else {
            firstTokenSampler = nil
        }
        defer { firstTokenSampler.map { llama_sampler_free($0) } }

        var generatedText = ""
        var position = Int32(promptTokens.count)
        var hasVisibleContent = false
        var shouldResetPromptCache = false
        defer {
            if shouldResetPromptCache {
                clearPromptCache()
            } else {
                discardCachedTokens(from: promptTokens.count, in: context)
            }
        }

        do {
            for tokenIndex in 0 ..< maxPredictionTokens {
                // Use the gated sampler only for the very first token (position 0).
                // After that, switch to the standard sampler so deny-listed tokens can appear
                // naturally in the middle of a continuation (e.g. "I" is fine as a second word).
                let activeSampler = (tokenIndex == 0 && firstTokenSampler != nil)
                    ? firstTokenSampler!
                    : sampler

                // Before sampling the first token through the gated chain, inspect the raw
                // logits to detect when the model's top choice would have been a deny-listed
                // token. This is the "gate fired" signal — the un-gated argmax check is a
                // sharper indicator than the actual sampled token (which could differ from
                // argmax under temperature/top-p), and it answers the practical question:
                // "did the gate prevent a chat-residue opener from being chosen?"
                if tokenIndex == 0 && firstTokenSampler != nil {
                    logFirstTokenGateFireIfNeeded(context: context, vocab: vocab)
                }

                // Confidence gating runs *before* sampling so we can abort the whole generation
                // (and avoid burning a sampled token + decode) when the model's distribution at
                // position 0 is too flat. The signal is the top-1 probability of the softmax over
                // the raw logits — not the post-sampler distribution — because temperature/top-p
                // shape the sampler's output, not the model's actual confidence.
                if tokenIndex == 0 && firstTokenConfidenceGatingEnabled {
                    if let suppression = lowConfidenceSuppressionIfNeeded(
                        context: context,
                        vocab: vocab,
                        threshold: firstTokenConfidenceThreshold
                    ) {
                        throw suppression
                    }
                }

                let nextToken = llama_sampler_sample(activeSampler, context, -1)
                if nextToken == llama_vocab_eos(vocab) || llama_vocab_is_eog(vocab, nextToken) {
                    break
                }

                let piece = pieceString(for: nextToken, vocab: vocab)
                generatedText += piece
                llama_sampler_accept(sampler, nextToken)

                // Instruction-shaped prompts often make small models emit a leading newline before the
                // actual continuation text. If we stop on the first newline unconditionally, guided
                // mode collapses into an empty suggestion even though the model would have produced a
                // usable fragment on the next token. We therefore allow leading formatting noise, but
                // still stop once a newline appears after the model has emitted any visible content.
                if piece.unicodeScalars.contains(where: Self.isVisibleOutputScalar) {
                    hasVisibleContent = true
                }

                if hasVisibleContent && generatedText.contains("\n") {
                    break
                }

                try decodeToken(nextToken, position: position, in: context)
                position += 1
            }
        } catch let error as LlamaRuntimeError {
            // Confidence suppression is a clean abort — the prompt KV is still valid and the next
            // request can reuse it. Reserve the cache reset for genuine generation failures.
            if case .lowConfidenceSuppression = error {
                throw error
            }
            shouldResetPromptCache = true
            throw error
        } catch {
            shouldResetPromptCache = true
            throw error
        }

        return generatedText
    }

    /// Drops the reusable prompt context while keeping the loaded model alive.
    func resetPromptCache() {
        clearPromptCache()
    }

    /// Frees any loaded model/backend state owned by the actor.
    func shutdown() {
        clearPromptCache()

        if let model {
            llama_model_free(model)
            self.model = nil
        }

        preparedRuntime = nil
        resolvedFirstTokenDenyList = []

        if backendInitialized {
            llama_backend_free()
            backendInitialized = false
        }
    }

    /// Returns a context whose KV memory represents `promptTokens`.
    /// Reuse is always validated at the token level before native memory is trusted. We also
    /// re-decode the final prompt token on every request so llama's current logits correspond to
    /// the prompt, not to the previous request's sampled continuation.
    private func preparePromptContext(
        model: OpaquePointer,
        preparedRuntime: PreparedLlamaRuntime,
        promptBytes: [UInt8],
        promptTokens: [llama_token],
        samplingFingerprint: SamplingFingerprint,
        cachedPrefixBytes: Int?
    ) throws -> OpaquePointer {
        guard let cachedPrefixBytes,
              cachedPrefixBytes > 0,
              let cache = promptCache,
              cache.samplingFingerprint == samplingFingerprint
        else {
            return try rebuildPromptContext(
                model: model,
                preparedRuntime: preparedRuntime,
                promptBytes: promptBytes,
                promptTokens: promptTokens,
                samplingFingerprint: samplingFingerprint
            )
        }

        let confirmedCommonBytes = min(
            cachedPrefixBytes,
            Self.commonPrefixCount(cache.promptBytes, promptBytes)
        )
        guard confirmedCommonBytes > 0 else {
            return try rebuildPromptContext(
                model: model,
                preparedRuntime: preparedRuntime,
                promptBytes: promptBytes,
                promptTokens: promptTokens,
                samplingFingerprint: samplingFingerprint
            )
        }

        let commonTokenPrefix = Self.commonPrefixCount(cache.promptTokens, promptTokens)
        let reusableTokenCount = Self.reusableTokenCount(
            commonTokenPrefix: commonTokenPrefix,
            newPromptTokenCount: promptTokens.count
        )

        guard trimCachedTokens(from: reusableTokenCount, in: cache.context) else {
            return try rebuildPromptContext(
                model: model,
                preparedRuntime: preparedRuntime,
                promptBytes: promptBytes,
                promptTokens: promptTokens,
                samplingFingerprint: samplingFingerprint
            )
        }

        do {
            try decodePrompt(
                promptTokens,
                startingAt: reusableTokenCount,
                in: cache.context,
                batchCapacity: preparedRuntime.batchSize
            )
        } catch {
            clearPromptCache()
            throw error
        }

        promptCache = PromptCache(
            context: cache.context,
            promptBytes: promptBytes,
            promptTokens: promptTokens,
            samplingFingerprint: samplingFingerprint
        )
        return cache.context
    }

    /// Builds a clean llama context and decodes the full prompt.
    /// This path is used for the first request, explicit invalidation, and any failed cache trim.
    private func rebuildPromptContext(
        model: OpaquePointer,
        preparedRuntime: PreparedLlamaRuntime,
        promptBytes: [UInt8],
        promptTokens: [llama_token],
        samplingFingerprint: SamplingFingerprint
    ) throws -> OpaquePointer {
        clearPromptCache()

        let context = try makeContext(
            model: model,
            contextWindowTokens: preparedRuntime.contextWindowTokens,
            batchSize: preparedRuntime.batchSize,
            threadCount: preparedRuntime.threadCount
        )

        do {
            try decodePrompt(
                promptTokens,
                startingAt: 0,
                in: context,
                batchCapacity: preparedRuntime.batchSize
            )
        } catch {
            llama_free(context)
            throw error
        }

        promptCache = PromptCache(
            context: context,
            promptBytes: promptBytes,
            promptTokens: promptTokens,
            samplingFingerprint: samplingFingerprint
        )
        return context
    }

    /// Frees the cached context. This is the native-resource counterpart to clearing a Swift cache.
    private func clearPromptCache() {
        if let promptCache {
            llama_free(promptCache.context)
            self.promptCache = nil
        }
    }

    /// Builds a fresh llama context for the prompt cache.
    private func makeContext(
        model: OpaquePointer,
        contextWindowTokens: Int,
        batchSize: Int,
        threadCount: Int
    ) throws -> OpaquePointer {
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextWindowTokens)
        contextParams.n_batch = UInt32(batchSize)
        contextParams.n_ubatch = UInt32(batchSize)
        contextParams.n_seq_max = 1
        contextParams.n_threads = Int32(threadCount)
        contextParams.n_threads_batch = Int32(threadCount)
        contextParams.offload_kqv = true

        guard let context = llama_init_from_model(model, contextParams) else {
            throw LlamaRuntimeError.generationFailed("Unable to create a llama context.")
        }

        return context
    }

    /// Tokenizes the prompt using the loaded model vocabulary and preserves special tokens.
    private func tokenize(_ prompt: String, vocab: OpaquePointer) throws -> [llama_token] {
        let utf8Count = max(prompt.utf8.count, 1)
        var capacity = utf8Count + 8
        let addSpecial = llama_vocab_get_add_bos(vocab)

        while true {
            var tokens = [llama_token](repeating: 0, count: capacity)
            let tokenCount = prompt.withCString { promptCString in
                llama_tokenize(
                    vocab,
                    promptCString,
                    Int32(prompt.utf8.count),
                    &tokens,
                    Int32(tokens.count),
                    addSpecial,
                    false
                )
            }

            if tokenCount > 0 {
                return Array(tokens.prefix(Int(tokenCount)))
            }

            if tokenCount == 0 {
                throw LlamaRuntimeError.generationFailed("Tokenization returned no prompt tokens.")
            }

            capacity = max(capacity * 2, Int(-tokenCount))
        }
    }

    /// Feeds prompt tokens through the context so sampling can begin from the final prompt state.
    private func decodePrompt(
        _ promptTokens: [llama_token],
        startingAt startIndex: Int,
        in context: OpaquePointer,
        batchCapacity: Int
    ) throws {
        let tokenCount = promptTokens.count - startIndex
        guard tokenCount > 0 else {
            return
        }

        var batch = llama_batch_init(Int32(max(tokenCount, batchCapacity)), 0, 1)
        defer { llama_batch_free(batch) }

        batch.n_tokens = Int32(tokenCount)

        for batchIndex in 0 ..< tokenCount {
            let tokenIndex = startIndex + batchIndex
            batch.token[batchIndex] = promptTokens[tokenIndex]
            batch.pos[batchIndex] = Int32(tokenIndex)
            batch.n_seq_id[batchIndex] = 1

            if let seqIDs = batch.seq_id, let seqID = seqIDs[batchIndex] {
                seqID[0] = Self.promptSequenceID
            }

            batch.logits[batchIndex] = 0
        }

        if batch.n_tokens > 0 {
            batch.logits[Int(batch.n_tokens) - 1] = 1
        }

        guard llama_decode(context, batch) == 0 else {
            throw LlamaRuntimeError.generationFailed("llama_decode failed while evaluating the prompt.")
        }
    }

    /// Advances the context by one sampled token so generation can continue autoregressively.
    private func decodeToken(
        _ token: llama_token,
        position: Int32,
        in context: OpaquePointer
    ) throws {
        var batch = llama_batch_init(1, 0, 1)
        defer { llama_batch_free(batch) }

        batch.n_tokens = 1
        batch.token[0] = token
        batch.pos[0] = position
        batch.n_seq_id[0] = 1

        if let seqIDs = batch.seq_id, let seqID = seqIDs[0] {
            seqID[0] = Self.promptSequenceID
        }

        batch.logits[0] = 1

        guard llama_decode(context, batch) == 0 else {
            throw LlamaRuntimeError.generationFailed("llama_decode failed while generating a continuation.")
        }
    }

    /// Inline autocomplete cares about visible suggestion text, not formatting-only tokens.
    /// We treat spaces/newlines/control scalars as non-visible so a leading newline does not count
    /// as "the model already started the answer."
    nonisolated private static func isVisibleOutputScalar(_ scalar: UnicodeScalar) -> Bool {
        if CharacterSet.controlCharacters.contains(scalar) {
            return false
        }

        return !CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// Assembles the sampler chain that controls temperature, nucleus sampling, and repetition behavior.
    private func makeSampler(
        temperature: Double,
        topK: Int,
        topP: Double,
        minP: Double,
        repetitionPenalty: Double,
        seed: UInt32?
    ) throws -> UnsafeMutablePointer<llama_sampler> {
        let params = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(params) else {
            throw LlamaRuntimeError.generationFailed("Unable to initialize the llama sampler chain.")
        }

        if repetitionPenalty > 1.0 {
            guard let penaltySampler = llama_sampler_init_penalties(64, Float(repetitionPenalty), 1.0, 1.0) else {
                throw LlamaRuntimeError.generationFailed("Unable to initialize the repetition penalty sampler.")
            }
            llama_sampler_chain_add(sampler, penaltySampler)
        }

        if temperature > 0 {
            guard let temperatureSampler = llama_sampler_init_temp(Float(temperature)) else {
                throw LlamaRuntimeError.generationFailed("Unable to initialize the temperature sampler.")
            }
            llama_sampler_chain_add(sampler, temperatureSampler)

            if topK > 0 {
                guard let topKSampler = llama_sampler_init_top_k(Int32(topK)) else {
                    throw LlamaRuntimeError.generationFailed("Unable to initialize the top-k sampler.")
                }
                llama_sampler_chain_add(sampler, topKSampler)
            }

            if minP > 0 && minP < 1 {
                guard let minPSampler = llama_sampler_init_min_p(Float(minP), 1) else {
                    throw LlamaRuntimeError.generationFailed("Unable to initialize the min-p sampler.")
                }
                llama_sampler_chain_add(sampler, minPSampler)
            }

            if topP > 0 && topP < 1 {
                guard let topPSampler = llama_sampler_init_top_p(Float(topP), 1) else {
                    throw LlamaRuntimeError.generationFailed("Unable to initialize the top-p sampler.")
                }
                llama_sampler_chain_add(sampler, topPSampler)
            }

            let resolvedSeed = seed ?? UInt32.random(in: UInt32.min ... UInt32.max)
            guard let distributionSampler = llama_sampler_init_dist(resolvedSeed) else {
                throw LlamaRuntimeError.generationFailed("Unable to initialize the distribution sampler.")
            }
            llama_sampler_chain_add(sampler, distributionSampler)
        } else {
            guard let greedySampler = llama_sampler_init_greedy() else {
                throw LlamaRuntimeError.generationFailed("Unable to initialize the greedy sampler.")
            }
            llama_sampler_chain_add(sampler, greedySampler)
        }

        return sampler
    }

    /// Builds a sampler chain with a logit-bias gate prepended that applies `-inf` to all
    /// resolved first-token deny-list entries. This chain is used only for the very first
    /// sampled token; subsequent tokens use the standard (ungated) sampler.
    ///
    /// The chain is otherwise identical to `makeSampler()` — same temperature, top-k, top-p,
    /// min-p, repetition penalty, and seed. We build a separate chain instead of mutating one
    /// mid-generation because it's easier to reason about and the init cost is negligible.
    private func makeFirstTokenGatedSampler(
        vocab: OpaquePointer,
        temperature: Double,
        topK: Int,
        topP: Double,
        minP: Double,
        repetitionPenalty: Double,
        seed: UInt32?
    ) throws -> UnsafeMutablePointer<llama_sampler> {
        let params = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(params) else {
            throw LlamaRuntimeError.generationFailed("Unable to initialize the first-token gated sampler chain.")
        }

        // Prepend the logit-bias stage so it runs before any other sampling transforms.
        // Each entry applies `-inf` bias, making the token impossible to sample.
        let nVocab = llama_vocab_n_tokens(vocab)
        var biases = resolvedFirstTokenDenyList
        guard let biasSampler = llama_sampler_init_logit_bias(
            nVocab,
            Int32(biases.count),
            &biases
        ) else {
            llama_sampler_free(sampler)
            throw LlamaRuntimeError.generationFailed("Unable to initialize the logit bias sampler for first-token gating.")
        }
        llama_sampler_chain_add(sampler, biasSampler)

        // The remaining stages mirror makeSampler() exactly.
        if repetitionPenalty > 1.0 {
            guard let penaltySampler = llama_sampler_init_penalties(64, Float(repetitionPenalty), 1.0, 1.0) else {
                llama_sampler_free(sampler)
                throw LlamaRuntimeError.generationFailed("Unable to initialize the repetition penalty sampler.")
            }
            llama_sampler_chain_add(sampler, penaltySampler)
        }

        if temperature > 0 {
            guard let temperatureSampler = llama_sampler_init_temp(Float(temperature)) else {
                llama_sampler_free(sampler)
                throw LlamaRuntimeError.generationFailed("Unable to initialize the temperature sampler.")
            }
            llama_sampler_chain_add(sampler, temperatureSampler)

            if topK > 0 {
                guard let topKSampler = llama_sampler_init_top_k(Int32(topK)) else {
                    llama_sampler_free(sampler)
                    throw LlamaRuntimeError.generationFailed("Unable to initialize the top-k sampler.")
                }
                llama_sampler_chain_add(sampler, topKSampler)
            }

            if minP > 0 && minP < 1 {
                guard let minPSampler = llama_sampler_init_min_p(Float(minP), 1) else {
                    llama_sampler_free(sampler)
                    throw LlamaRuntimeError.generationFailed("Unable to initialize the min-p sampler.")
                }
                llama_sampler_chain_add(sampler, minPSampler)
            }

            if topP > 0 && topP < 1 {
                guard let topPSampler = llama_sampler_init_top_p(Float(topP), 1) else {
                    llama_sampler_free(sampler)
                    throw LlamaRuntimeError.generationFailed("Unable to initialize the top-p sampler.")
                }
                llama_sampler_chain_add(sampler, topPSampler)
            }

            let resolvedSeed = seed ?? UInt32.random(in: UInt32.min ... UInt32.max)
            guard let distributionSampler = llama_sampler_init_dist(resolvedSeed) else {
                llama_sampler_free(sampler)
                throw LlamaRuntimeError.generationFailed("Unable to initialize the distribution sampler.")
            }
            llama_sampler_chain_add(sampler, distributionSampler)
        } else {
            guard let greedySampler = llama_sampler_init_greedy() else {
                llama_sampler_free(sampler)
                throw LlamaRuntimeError.generationFailed("Unable to initialize the greedy sampler.")
            }
            llama_sampler_chain_add(sampler, greedySampler)
        }

        return sampler
    }

    /// Converts the human-readable deny strings from `FirstTokenDenyList` into concrete
    /// `llama_logit_bias` entries using the loaded model's vocabulary.
    ///
    /// For each deny string, we tokenize it and take only the **first** token. This is correct
    /// because we only gate position 0 — whether "Sure," tokenizes as one token `["Sure,"]` or
    /// two tokens `["Sure", ","]`, we want to block the leading token `"Sure"` (or `"Sure,"`)
    /// at position 0.
    ///
    /// Duplicate token IDs are deduplicated so each token appears at most once in the bias array.
    private func resolveFirstTokenDenyList(
        for modelFilename: String,
        model: OpaquePointer
    ) -> [llama_logit_bias] {
        guard let vocab = llama_model_get_vocab(model) else {
            return []
        }

        let denyStrings = FirstTokenDenyList.denyStrings(for: modelFilename)
        var seenTokenIDs: Set<llama_token> = []
        var biases: [llama_logit_bias] = []

        for denyString in denyStrings {
            // Tokenize without adding BOS — we want the raw token for the string fragment,
            // not a sequence that starts with the model's beginning-of-sequence marker.
            guard let firstToken = tokenizeFirstToken(denyString, vocab: vocab) else {
                continue
            }

            // Deduplicate: different deny strings may resolve to the same leading token
            // (e.g. "Sure" and "Sure," might both start with token ID 12345).
            guard seenTokenIDs.insert(firstToken).inserted else {
                continue
            }

            biases.append(llama_logit_bias(token: firstToken, bias: -.infinity))
        }

        return biases
    }

    /// Detects when the gate is about to suppress the model's top-of-distribution choice and logs
    /// a debug-level signal naming the suppressed token. We compute the un-gated argmax over the
    /// raw logits at the last context position; if that argmax token sits in the resolved deny
    /// set, the gate fired meaningfully on this generation.
    ///
    /// We check argmax (greedy) rather than the actual sampled token because the sampled token
    /// passes through temperature/top-p/min-p stochastic stages — argmax is the precise answer
    /// to "what was the model's strongest preference?" which is what the gate is defending
    /// against. Cost is one O(nVocab) scan, only on the first token, only when gating is on.
    private func logFirstTokenGateFireIfNeeded(
        context: OpaquePointer,
        vocab: OpaquePointer
    ) {
        guard !resolvedFirstTokenDenyList.isEmpty,
              let logits = llama_get_logits_ith(context, -1)
        else { return }

        let nVocab = Int(llama_vocab_n_tokens(vocab))
        guard nVocab > 0 else { return }

        var bestTokenID: llama_token = 0
        var bestLogit: Float = -.infinity
        for tokenID in 0 ..< nVocab {
            let value = logits[tokenID]
            if value > bestLogit {
                bestLogit = value
                bestTokenID = llama_token(tokenID)
            }
        }

        guard resolvedFirstTokenDenyList.contains(where: { $0.token == bestTokenID }) else {
            return
        }

        let piece = pieceString(for: bestTokenID, vocab: vocab)
        let escaped = piece
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        Self.firstTokenGateLogger.debug(
            "gate suppressed token \(bestTokenID, privacy: .public) (\"\(escaped, privacy: .public)\", logit=\(bestLogit, privacy: .public))"
        )
    }

    /// Checks the model's confidence at position 0 and returns a suppression error if it is too
    /// low. Confidence is defined as the **top-1 probability of the softmax over the raw logits**
    /// at the last context position — i.e. how peaked the model's actual distribution is, before
    /// any sampler-chain transforms.
    ///
    /// We deliberately don't use the *sampled* token's post-transform probability: temperature,
    /// top-p, and min-p reshape the distribution, so a sampled-token probability of 0.9 after
    /// top-p can correspond to a raw distribution where the true top-1 was 0.05 (the model was
    /// confused, but the sampler concentrated mass on a survivor). For inline autocomplete we
    /// want to suppress when *the model itself* was uncertain, not when the sampler happened to
    /// be confident about a leftover.
    ///
    /// Implementation note: we compute softmax in a numerically-stable way (subtract max logit
    /// before exp) over the full vocabulary. This is one O(nVocab) pass — same cost as the gate
    /// argmax — and it only runs once per generation when confidence gating is enabled.
    private func lowConfidenceSuppressionIfNeeded(
        context: OpaquePointer,
        vocab: OpaquePointer,
        threshold: Double
    ) -> LlamaRuntimeError? {
        guard let logits = llama_get_logits_ith(context, -1) else {
            return nil
        }

        let nVocab = Int(llama_vocab_n_tokens(vocab))
        guard nVocab > 0 else { return nil }

        var maxLogit: Float = -.infinity
        var argmaxTokenID: llama_token = 0
        for tokenID in 0 ..< nVocab {
            let value = logits[tokenID]
            if value > maxLogit {
                maxLogit = value
                argmaxTokenID = llama_token(tokenID)
            }
        }

        // Numerically-stable softmax: subtract the max before exponentiating so we don't overflow
        // float on large logits. The probability of the argmax token is then
        //   exp(0) / sum(exp(logit_i - max)) = 1 / sum(exp(logit_i - max))
        var expSum: Double = 0
        for tokenID in 0 ..< nVocab {
            expSum += Double(exp(logits[tokenID] - maxLogit))
        }
        guard expSum > 0 else { return nil }

        let topProbability = Float(1.0 / expSum)

        guard Double(topProbability) < threshold else {
            return nil
        }

        let piece = pieceString(for: argmaxTokenID, vocab: vocab)
        let escaped = piece
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        Self.firstTokenConfidenceLogger.debug(
            "suppressed: top-1 token \(argmaxTokenID, privacy: .public) (\"\(escaped, privacy: .public)\") prob=\(topProbability, privacy: .public) threshold=\(threshold, privacy: .public)"
        )

        return .lowConfidenceSuppression(
            probability: topProbability,
            threshold: threshold,
            token: piece
        )
    }

    /// Tokenizes a short string and returns just the first token, without BOS.
    /// Returns nil if tokenization fails or produces no tokens.
    private func tokenizeFirstToken(_ text: String, vocab: OpaquePointer) -> llama_token? {
        let utf8Count = max(text.utf8.count, 1)
        let capacity = utf8Count + 8
        var tokens = [llama_token](repeating: 0, count: capacity)

        let tokenCount = text.withCString { cString in
            llama_tokenize(
                vocab,
                cString,
                Int32(text.utf8.count),
                &tokens,
                Int32(tokens.count),
                false,  // add_special = false: no BOS, we want the raw fragment token
                false
            )
        }

        guard tokenCount > 0 else {
            return nil
        }

        return tokens[0]
    }

    /// Removes tokens at and after `position` from the prompt sequence.
    /// llama.cpp returns `false` when a partial removal is unsupported by the current memory type;
    /// callers then fall back to a fresh context rather than risking stale KV state.
    private func trimCachedTokens(from position: Int, in context: OpaquePointer) -> Bool {
        guard let memory = llama_get_memory(context) else {
            return false
        }

        return llama_memory_seq_rm(
            memory,
            Self.promptSequenceID,
            llama_pos(position),
            -1
        )
    }

    /// Removes sampled continuation tokens so the retained context represents only the prompt.
    /// The next request will re-decode the final prompt token to refresh logits before sampling.
    private func discardCachedTokens(from position: Int, in context: OpaquePointer) {
        _ = trimCachedTokens(from: position, in: context)
    }

    private static func reusableTokenCount(commonTokenPrefix: Int, newPromptTokenCount: Int) -> Int {
        guard newPromptTokenCount > 1 else {
            return 0
        }

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

    /// Converts one sampled token back into its text piece representation.
    private func pieceString(for token: llama_token, vocab: OpaquePointer) -> String {
        var bufferLength = 32

        while true {
            var buffer = [CChar](repeating: 0, count: bufferLength)
            let written = llama_token_to_piece(
                vocab,
                token,
                &buffer,
                Int32(buffer.count),
                0,
                false
            )

            if written < 0 {
                bufferLength = max(bufferLength * 2, Int(-written) + 1)
                continue
            }

            let bytes = buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
