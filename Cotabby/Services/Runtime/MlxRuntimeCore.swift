import Foundation
import Logging
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// File overview:
/// Owns MLX model lifecycle and the autocomplete KV-cache state.
///
/// This is the MLX counterpart to `LlamaRuntimeCore`: the manager publishes UI state, while this
/// core owns backend correctness. The cache bookkeeping lives here because prompt tokens, sampled
/// tokens, and backend cache objects must stay in lockstep; spreading that across UI-facing types
/// would make cancellation and stale-cache bugs much easier to introduce.
nonisolated final class MlxRuntimeCore: @unchecked Sendable {
    private var preparedRuntime: PreparedMlxRuntime?
    private var modelContainer: ModelContainer?
    private var autocompleteCache: [KVCache]?

    /// Serializes the whole cache-backed decode without relying on thread ownership.
    ///
    /// Generation suspends while MLX produces tokens and may resume on another cooperative-pool
    /// thread. Unlike `NSLock`, a semaphore may be signalled from that different thread, so it is
    /// safe to hold across the `await` while still preventing overlapping cache mutations.
    private let autocompleteSemaphore = DispatchSemaphore(value: 1)
    private var autocompletePromptBytes: [UInt8] = []
    private var autocompletePromptTokens: [Int] = []
    private var autocompleteSamplingFingerprint: String?

    private var autocompleteCacheIsPresent = false

    private let lifecycleCondition = NSCondition()
    private var activeOperationCount = 0
    private var isShuttingDown = false

    func prepare(
        resolvedRuntime: ResolvedMlxRuntime,
        configuration: MlxRuntimeConfiguration
    ) async throws -> PreparedMlxRuntime {
        if let preparedRuntime,
           preparedRuntime.resolvedRuntime.modelDirectoryURL == resolvedRuntime.modelDirectoryURL {
            return preparedRuntime
        }

        if preparedRuntime != nil {
            shutdown()
        }

        CotabbyLogger.runtime.info(
            "Loading MLX model",
            metadata: [
                "model_id": .string(resolvedRuntime.modelID),
                "model_path": .string(resolvedRuntime.modelDirectoryURL.path),
                "prefill_step_size": .stringConvertible(configuration.prefillStepSize),
                "max_kv_size": .string(configuration.maxKVSize.map(String.init) ?? "none"),
                "kv_bits": .string(configuration.kvBits.map(String.init) ?? "none")
            ]
        )

        do {
            // Importing `MLXLLM` above registers its model factory trampoline. Loading still happens
            // from Cotabby's local snapshot directory, so generation remains local after download.
            let container = try await loadModelContainer(
                from: resolvedRuntime.modelDirectoryURL,
                using: MlxLocalTokenizerLoader()
            )
            let contextWindowTokens = Self.contextWindowTokens(in: resolvedRuntime.modelDirectoryURL)
            let preparedRuntime = PreparedMlxRuntime(
                resolvedRuntime: resolvedRuntime,
                backendName: "MLX Swift LM",
                contextWindowTokens: contextWindowTokens,
                maxKVSize: configuration.maxKVSize,
                kvBits: configuration.kvBits,
                prefillStepSize: configuration.prefillStepSize
            )

            modelContainer = container
            self.preparedRuntime = preparedRuntime
            resetPromptCache()
            CotabbyLogger.runtime.info(
                "MLX model loaded",
                metadata: [
                    "model_id": .string(resolvedRuntime.modelID),
                    "backend": .string(preparedRuntime.backendName),
                    "context_window_tokens": .string(contextWindowTokens.map(String.init) ?? "unknown")
                ]
            )
            return preparedRuntime
        } catch is CancellationError {
            throw MlxRuntimeError.cancelled
        } catch let error as MlxRuntimeError {
            throw error
        } catch {
            throw MlxRuntimeError.unavailable(
                "Unable to load MLX model from \(resolvedRuntime.modelDirectoryURL.path): \(error.localizedDescription)"
            )
        }
    }

    func generate(
        prompt: String,
        cachedPrefixBytes: Int?,
        options: LlamaGenerationOptions,
        configuration: MlxRuntimeConfiguration
    ) async throws -> String {
        guard let preparedRuntime, let modelContainer else {
            throw MlxRuntimeError.unavailable("The MLX model is not loaded.")
        }

        lifecycleCondition.lock()
        guard !isShuttingDown else {
            lifecycleCondition.unlock()
            throw MlxRuntimeError.unavailable("The MLX runtime is shutting down.")
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
        let allPromptTokens = await modelContainer.encode(prompt)
        guard !allPromptTokens.isEmpty else {
            CotabbyLogger.runtime.error(
                "MLX tokenization returned no prompt tokens",
                metadata: ["prompt_bytes": .stringConvertible(promptBytes.count)]
            )
            throw MlxRuntimeError.generationFailed("MLX tokenization returned no prompt tokens.")
        }

        let maxPromptTokens = preparedRuntime.contextWindowTokens.map {
            max(1, $0 - options.maxPredictionTokens)
        }
        let promptTokens: [Int]
        let adjustedCachedPrefixBytes: Int?
        if let maxPromptTokens, allPromptTokens.count > maxPromptTokens {
            promptTokens = Array(allPromptTokens.suffix(maxPromptTokens))
            adjustedCachedPrefixBytes = nil
        } else {
            promptTokens = allPromptTokens
            adjustedCachedPrefixBytes = cachedPrefixBytes
        }

        CotabbyLogger.runtime.debug(
            "MLX decode start",
            metadata: [
                "prompt_tokens": .stringConvertible(promptTokens.count),
                "max_tokens": .stringConvertible(options.maxPredictionTokens),
                "cached_prefix_bytes": .string(adjustedCachedPrefixBytes.map(String.init) ?? "none")
            ]
        )

        let fingerprint = samplingFingerprint(options: options, configuration: configuration)
        let generationParameters = Self.generateParameters(options: options, configuration: configuration)

        autocompleteSemaphore.wait()
        defer { autocompleteSemaphore.signal() }
        try Task.checkCancellation()

        let preparedPrompt = preparePromptCache(
            promptTokens: promptTokens,
            promptBytes: promptBytes,
            fingerprint: fingerprint,
            cachedPrefixBytes: adjustedCachedPrefixBytes
        )
        logCacheDecision(preparedPrompt.decision)

        let generated: GeneratedText
        do {
            generated = try await modelContainer.perform { context in
                let cache = autocompleteCache ?? context.model.newCache(parameters: generationParameters)
                autocompleteCache = cache
                // Tokens must be a 1-D (L,) array: MLX Swift LM adds the batch axis itself inside its
                // decode loop (`model(previous[text: .newAxis], …)`). Pre-adding `[.newAxis]` here would
                // double-batch the prompt, collapsing the hidden-state shape and aborting the first
                // attention matmul (`[quantized_matmul] … does not match …`). Every canonical
                // `LMInput(tokens:)` usage in mlx-swift-lm passes the bare `MLXArray(tokens)`.
                let input = LMInput(tokens: MLXArray(preparedPrompt.inputTokens))
                let stream = try generateTokens(
                    input: input,
                    cache: cache,
                    parameters: generationParameters,
                    context: context
                )
                return try await Self.collectGeneratedText(
                    stream: stream,
                    tokenizer: context.tokenizer,
                    options: options
                )
            }
        } catch {
            // MLX mutates the cache as it evaluates prompt and generated tokens. If generation is
            // cancelled or throws, the exact processed depth is unavailable, so retaining the old
            // prompt metadata would make the next reuse decision trim against a different cache.
            resetPromptCacheLocked()
            throw error
        }

        if let autocompleteCache, generated.tokensGenerated > 0 {
            _ = trimPromptCache(autocompleteCache, numTokens: generated.tokensGenerated)
        }

        autocompletePromptBytes = promptBytes
        autocompletePromptTokens = promptTokens
        autocompleteSamplingFingerprint = fingerprint
        autocompleteCacheIsPresent = autocompleteCache != nil

        CotabbyLogger.runtime.debug(
            "MLX decode end",
            metadata: [
                "tokens_generated": .stringConvertible(generated.tokensGenerated),
                "chars_generated": .stringConvertible(generated.text.count),
                "stop_reason": .string(generated.stopReason)
            ]
        )

        return generated.text
    }

    func resetPromptCache() {
        autocompleteSemaphore.wait()
        defer { autocompleteSemaphore.signal() }
        resetPromptCacheLocked()
    }

    func shutdown(timeoutSeconds: TimeInterval? = nil) {
        CotabbyLogger.runtime.info(
            "MLX runtime shutdown requested",
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
        preparedRuntime = nil
        modelContainer = nil
        CotabbyLogger.runtime.info("MLX runtime shutdown complete")

        lifecycleCondition.lock()
        isShuttingDown = false
        lifecycleCondition.unlock()
    }

    private var cacheIsTrimmable: Bool {
        guard let autocompleteCache else { return false }
        return canTrimPromptCache(autocompleteCache)
    }

    private func resetPromptCacheLocked() {
        autocompletePromptBytes = []
        autocompletePromptTokens = []
        autocompleteSamplingFingerprint = nil
        autocompleteCache = nil
        autocompleteCacheIsPresent = false
        CotabbyLogger.runtime.debug("MLX prompt cache reset")
    }

    private func logCacheDecision(_ decision: MlxPromptCacheDecision) {
        switch decision.action {
        case .fresh(let reason):
            CotabbyLogger.runtime.debug(
                "MLX cache fresh prefill",
                metadata: ["cache_reset_reason": .string(reason)]
            )
        case .reuse(let commonPrefixTokens):
            CotabbyLogger.runtime.debug(
                "MLX cache reuse",
                metadata: ["cache_reuse_tokens": .stringConvertible(commonPrefixTokens)]
            )
        }
    }

    private func samplingFingerprint(
        options: LlamaGenerationOptions,
        configuration: MlxRuntimeConfiguration
    ) -> String {
        [
            String(options.maxPredictionTokens),
            String(options.temperature),
            String(options.topK),
            String(options.topP),
            String(options.minP),
            String(options.repetitionPenalty),
            String(options.seed ?? 0),
            String(configuration.maxKVSize ?? -1),
            String(configuration.kvBits ?? -1),
            String(configuration.prefillStepSize)
        ].joined(separator: "|")
    }

    private struct PreparedPromptCacheInput: Sendable {
        let decision: MlxPromptCacheDecision
        let inputTokens: [Int]
    }

    private func preparePromptCache(
        promptTokens: [Int],
        promptBytes: [UInt8],
        fingerprint: String,
        cachedPrefixBytes: Int?
    ) -> PreparedPromptCacheInput {
        let decision = MlxPromptCachePlanner.decision(
            cachedTokens: autocompletePromptTokens,
            newTokens: promptTokens,
            cachedFingerprint: autocompleteSamplingFingerprint,
            newFingerprint: fingerprint,
            cacheIsTrimmable: cacheIsTrimmable
        )

        guard case .reuse(let commonPrefixTokens) = decision.action,
              let cachedPrefixBytes, cachedPrefixBytes > 0,
              Self.commonPrefixCount(autocompletePromptBytes, promptBytes) > 0,
              let autocompleteCache
        else {
            resetPromptCacheLocked()
            return PreparedPromptCacheInput(decision: decision, inputTokens: promptTokens)
        }

        // MLX's generator consumes input tokens against the cache. If the cache already contains the
        // full prompt, keep all but the final token and replay that last token so the next-token
        // logits are produced from a valid autoregressive step rather than an empty input.
        let maxReusableTokenCount = max(0, promptTokens.count - 1)
        let reusableTokenCount = min(commonPrefixTokens, maxReusableTokenCount)
        let tokensToTrim = max(0, autocompletePromptTokens.count - reusableTokenCount)
        if tokensToTrim > 0 {
            let trimmed = trimPromptCache(autocompleteCache, numTokens: tokensToTrim)
            if trimmed != tokensToTrim {
                resetPromptCacheLocked()
                return PreparedPromptCacheInput(
                    decision: MlxPromptCacheDecision(action: .fresh(reason: "cache_trim_failed")),
                    inputTokens: promptTokens
                )
            }
        }

        return PreparedPromptCacheInput(
            decision: decision,
            inputTokens: Array(promptTokens[reusableTokenCount...])
        )
    }

    private static func generateParameters(
        options: LlamaGenerationOptions,
        configuration: MlxRuntimeConfiguration
    ) -> GenerateParameters {
        GenerateParameters(
            maxTokens: options.maxPredictionTokens,
            maxKVSize: configuration.maxKVSize,
            kvBits: configuration.kvBits,
            temperature: Float(options.temperature),
            topP: Float(options.topP),
            topK: options.topK,
            minP: Float(options.minP),
            repetitionPenalty: options.repetitionPenalty == 1 ? nil : Float(options.repetitionPenalty),
            prefillStepSize: configuration.prefillStepSize
        )
    }

    private struct GeneratedText: Sendable {
        let text: String
        let tokensGenerated: Int
        let stopReason: String
    }

    private static func collectGeneratedText(
        stream: AsyncStream<TokenGeneration>,
        tokenizer: any MLXLMCommon.Tokenizer,
        options: LlamaGenerationOptions
    ) async throws -> GeneratedText {
        var generatedText = ""
        var tokensGenerated = 0
        var stopReason = "budget_exhausted"
        var detokenizer = NaiveStreamingDetokenizer(tokenizer: tokenizer)

        for await event in stream {
            try Task.checkCancellation()

            switch event {
            case .token(let token):
                tokensGenerated += 1
                detokenizer.append(token: token)
                guard let piece = detokenizer.next() else {
                    continue
                }
                generatedText += piece

                if options.singleLine, generatedText.contains(where: \.isNewline) {
                    generatedText = String(generatedText.prefix { !$0.isNewline })
                    stopReason = "newline"
                    return GeneratedText(
                        text: generatedText,
                        tokensGenerated: tokensGenerated,
                        stopReason: stopReason
                    )
                }

                if DecodeStopPolicy.shouldStop(
                    accumulated: generatedText,
                    tokensGenerated: tokensGenerated,
                    minimumTokens: options.sentenceStopMinimumTokens
                ) {
                    stopReason = "sentence_boundary"
                    return GeneratedText(
                        text: generatedText,
                        tokensGenerated: tokensGenerated,
                        stopReason: stopReason
                    )
                }
            case .info(let info):
                stopReason = Self.stopReasonDescription(info.stopReason)
                return GeneratedText(
                    text: generatedText,
                    tokensGenerated: info.generationTokenCount,
                    stopReason: stopReason
                )
            }
        }

        return GeneratedText(
            text: generatedText,
            tokensGenerated: tokensGenerated,
            stopReason: stopReason
        )
    }

    private static func stopReasonDescription(_ reason: GenerateStopReason) -> String {
        switch reason {
        case .stop:
            return "eos"
        case .length:
            return "budget_exhausted"
        case .cancelled:
            return "cancelled"
        }
    }

    private static func commonPrefixCount<Element: Equatable>(_ lhs: [Element], _ rhs: [Element]) -> Int {
        var index = 0
        let limit = min(lhs.count, rhs.count)
        while index < limit, lhs[index] == rhs[index] {
            index += 1
        }
        return index
    }

    private static func contextWindowTokens(in modelDirectoryURL: URL) -> Int? {
        let configURL = modelDirectoryURL.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let keys = [
            "max_position_embeddings",
            "model_max_length",
            "max_sequence_length",
            "seq_length",
            "n_positions"
        ]
        for key in keys {
            if let value = object[key] as? Int {
                return value
            }
            if let value = object[key] as? NSNumber {
                return value.intValue
            }
        }
        return nil
    }
}

/// Bridges Swift Transformers tokenizers into MLX Swift LM's small tokenizer protocol.
///
/// MLX ships macros that generate this adapter, but Xcode command-line builds require explicit
/// macro approval. Keeping the bridge as ordinary Swift preserves the same runtime behavior while
/// avoiding a build-time trust prompt for Cotabby contributors and CI.
private struct MlxLocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return MlxTokenizerBridge(upstream)
    }
}

private struct MlxTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
