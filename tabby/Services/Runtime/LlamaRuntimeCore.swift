import Foundation
import LlamaSwift

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

    private var backendInitialized = false
    private var model: OpaquePointer?
    private var preparedRuntime: PreparedLlamaRuntime?
    private var promptCache: PromptCache?

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

    private struct PromptContextRequest {
        let promptBytes: [UInt8]
        let promptTokens: [llama_token]
        let samplingFingerprint: SamplingFingerprint
        let cachedPrefixBytes: Int?
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
        options: LlamaGenerationOptions
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

        let allPromptTokens = try tokenize(prompt, vocab: vocab)

        // Reserve space for generation and trim from the front if needed. The tail of the prompt
        // is closest to the caret and matters most for completion quality.
        let maxPromptTokens = max(1, preparedRuntime.contextWindowTokens - options.maxPredictionTokens)
        let promptTokens: [llama_token]
        let adjustedCachedPrefixBytes: Int?
        if allPromptTokens.count > maxPromptTokens {
            promptTokens = Array(allPromptTokens.suffix(maxPromptTokens))
            // Front-trimming invalidates any byte-level prefix overlap with the cache.
            adjustedCachedPrefixBytes = nil
        } else {
            promptTokens = allPromptTokens
            adjustedCachedPrefixBytes = cachedPrefixBytes
        }

        let promptBytes = Array(prompt.utf8)
        let contextRequest = PromptContextRequest(
            promptBytes: promptBytes,
            promptTokens: promptTokens,
            samplingFingerprint: SamplingFingerprint(options: options),
            cachedPrefixBytes: adjustedCachedPrefixBytes
        )
        let context = try preparePromptContext(
            model: model,
            preparedRuntime: preparedRuntime,
            request: contextRequest
        )

        let sampler = try makeSampler(options: options)
        defer { llama_sampler_free(sampler) }

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
            for _ in 0 ..< options.maxPredictionTokens {
                let nextToken = llama_sampler_sample(sampler, context, -1)
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
        request: PromptContextRequest
    ) throws -> OpaquePointer {
        guard let cachedPrefixBytes = request.cachedPrefixBytes,
              cachedPrefixBytes > 0,
              let cache = promptCache,
              cache.samplingFingerprint == request.samplingFingerprint
        else {
            return try rebuildPromptContext(
                model: model,
                preparedRuntime: preparedRuntime,
                promptBytes: request.promptBytes,
                promptTokens: request.promptTokens,
                samplingFingerprint: request.samplingFingerprint
            )
        }

        let confirmedCommonBytes = min(
            cachedPrefixBytes,
            Self.commonPrefixCount(cache.promptBytes, request.promptBytes)
        )
        guard confirmedCommonBytes > 0 else {
            return try rebuildPromptContext(
                model: model,
                preparedRuntime: preparedRuntime,
                promptBytes: request.promptBytes,
                promptTokens: request.promptTokens,
                samplingFingerprint: request.samplingFingerprint
            )
        }

        let commonTokenPrefix = Self.commonPrefixCount(cache.promptTokens, request.promptTokens)
        let reusableTokenCount = Self.reusableTokenCount(
            commonTokenPrefix: commonTokenPrefix,
            newPromptTokenCount: request.promptTokens.count
        )

        guard trimCachedTokens(from: reusableTokenCount, in: cache.context) else {
            return try rebuildPromptContext(
                model: model,
                preparedRuntime: preparedRuntime,
                promptBytes: request.promptBytes,
                promptTokens: request.promptTokens,
                samplingFingerprint: request.samplingFingerprint
            )
        }

        do {
            try decodePrompt(
                request.promptTokens,
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
            promptBytes: request.promptBytes,
            promptTokens: request.promptTokens,
            samplingFingerprint: request.samplingFingerprint
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

    /// Feeds prompt tokens through the context in chunks that respect `batchCapacity` so
    /// `llama_decode` never receives more tokens than `n_batch` / `n_ubatch` allow.
    private func decodePrompt(
        _ promptTokens: [llama_token],
        startingAt startIndex: Int,
        in context: OpaquePointer,
        batchCapacity: Int
    ) throws {
        let totalTokens = promptTokens.count - startIndex
        guard totalTokens > 0 else {
            return
        }

        var batch = llama_batch_init(Int32(batchCapacity), 0, 1)
        defer { llama_batch_free(batch) }

        var cursor = startIndex
        let endIndex = promptTokens.count

        while cursor < endIndex {
            let chunkEnd = min(cursor + batchCapacity, endIndex)
            let chunkSize = chunkEnd - cursor

            batch.n_tokens = Int32(chunkSize)

            for offset in 0 ..< chunkSize {
                let tokenIndex = cursor + offset
                batch.token[offset] = promptTokens[tokenIndex]
                batch.pos[offset] = Int32(tokenIndex)
                batch.n_seq_id[offset] = 1

                if let seqIDs = batch.seq_id, let seqID = seqIDs[offset] {
                    seqID[0] = Self.promptSequenceID
                }

                // Only request logits for the very last token of the entire prompt.
                batch.logits[offset] = (chunkEnd == endIndex && offset == chunkSize - 1) ? 1 : 0
            }

            guard llama_decode(context, batch) == 0 else {
                throw LlamaRuntimeError.generationFailed("llama_decode failed while evaluating the prompt.")
            }

            cursor = chunkEnd
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
    private func makeSampler(options: LlamaGenerationOptions) throws -> UnsafeMutablePointer<llama_sampler> {
        let params = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(params) else {
            throw LlamaRuntimeError.generationFailed("Unable to initialize the llama sampler chain.")
        }

        try addPenaltySamplerIfNeeded(to: sampler, repetitionPenalty: options.repetitionPenalty)

        if options.temperature > 0 {
            try addRandomSamplingChain(to: sampler, options: options)
        } else {
            try addGreedySampler(to: sampler)
        }

        return sampler
    }

    private func addPenaltySamplerIfNeeded(
        to sampler: UnsafeMutablePointer<llama_sampler>,
        repetitionPenalty: Double
    ) throws {
        guard repetitionPenalty > 1.0 else {
            return
        }

        guard let penaltySampler = llama_sampler_init_penalties(
            64,
            Float(repetitionPenalty),
            1.0,
            1.0
        ) else {
            throw LlamaRuntimeError.generationFailed("Unable to initialize the repetition penalty sampler.")
        }
        llama_sampler_chain_add(sampler, penaltySampler)
    }

    private func addRandomSamplingChain(
        to sampler: UnsafeMutablePointer<llama_sampler>,
        options: LlamaGenerationOptions
    ) throws {
        guard let temperatureSampler = llama_sampler_init_temp(Float(options.temperature)) else {
            throw LlamaRuntimeError.generationFailed("Unable to initialize the temperature sampler.")
        }
        llama_sampler_chain_add(sampler, temperatureSampler)

        if options.topK > 0 {
            guard let topKSampler = llama_sampler_init_top_k(Int32(options.topK)) else {
                throw LlamaRuntimeError.generationFailed("Unable to initialize the top-k sampler.")
            }
            llama_sampler_chain_add(sampler, topKSampler)
        }

        if options.minP > 0 && options.minP < 1 {
            guard let minPSampler = llama_sampler_init_min_p(Float(options.minP), 1) else {
                throw LlamaRuntimeError.generationFailed("Unable to initialize the min-p sampler.")
            }
            llama_sampler_chain_add(sampler, minPSampler)
        }

        if options.topP > 0 && options.topP < 1 {
            guard let topPSampler = llama_sampler_init_top_p(Float(options.topP), 1) else {
                throw LlamaRuntimeError.generationFailed("Unable to initialize the top-p sampler.")
            }
            llama_sampler_chain_add(sampler, topPSampler)
        }

        let resolvedSeed = options.seed ?? UInt32.random(in: UInt32.min ... UInt32.max)
        guard let distributionSampler = llama_sampler_init_dist(resolvedSeed) else {
            throw LlamaRuntimeError.generationFailed("Unable to initialize the distribution sampler.")
        }
        llama_sampler_chain_add(sampler, distributionSampler)
    }

    private func addGreedySampler(to sampler: UnsafeMutablePointer<llama_sampler>) throws {
        guard let greedySampler = llama_sampler_init_greedy() else {
            throw LlamaRuntimeError.generationFailed("Unable to initialize the greedy sampler.")
        }
        llama_sampler_chain_add(sampler, greedySampler)
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
            return String(bytes: bytes, encoding: .utf8) ?? ""
        }
    }
}

extension LlamaRuntimeCore {
    /// Generates a summary without reading or modifying the global KV prompt cache.
    func summarize(
        prompt: String,
        options: LlamaGenerationOptions
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

        let allPromptTokens = try tokenize(prompt, vocab: vocab)
        let maxPromptTokens = max(1, preparedRuntime.contextWindowTokens - options.maxPredictionTokens)
        let promptTokens = allPromptTokens.count > maxPromptTokens
            ? Array(allPromptTokens.suffix(maxPromptTokens))
            : allPromptTokens

        let context = try makeContext(
            model: model,
            contextWindowTokens: preparedRuntime.contextWindowTokens,
            batchSize: preparedRuntime.batchSize,
            threadCount: preparedRuntime.threadCount
        )
        defer { llama_free(context) }

        try decodePrompt(
            promptTokens,
            startingAt: 0,
            in: context,
            batchCapacity: preparedRuntime.batchSize
        )

        let sampler = try makeSampler(options: options)
        defer { llama_sampler_free(sampler) }

        var generatedText = ""
        var position = Int32(promptTokens.count)

        for _ in 0 ..< options.maxPredictionTokens {
            // Cooperative cancellation: if the caller's Task is cancelled (e.g. timeout),
            // return whatever text was generated so far instead of blocking until completion.
            if Task.isCancelled {
                break
            }

            let nextToken = llama_sampler_sample(sampler, context, -1)
            if nextToken == llama_vocab_eos(vocab) || llama_vocab_is_eog(vocab, nextToken) {
                break
            }

            let piece = pieceString(for: nextToken, vocab: vocab)
            generatedText += piece
            llama_sampler_accept(sampler, nextToken)

            try decodeToken(nextToken, position: position, in: context)
            position += 1
        }

        return generatedText
    }
}
