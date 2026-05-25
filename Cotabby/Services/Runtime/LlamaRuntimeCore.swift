import Foundation
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

        let status = engine.loadModel(
            resolvedRuntime.modelFileURL.path,
            configuration.gpuLayerCount,
            configuration.contextWindowTokens,
            configuration.batchSize
        )

        guard status == .ok else {
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
            throw LlamaRuntimeError.generationFailed("Tokenization returned no prompt tokens.")
        }

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

        var generatedText = ""

        for _ in 0 ..< options.maxPredictionTokens {
            let result = engine.sampleNext(sequenceID)

            if result.was_cancelled || result.is_eos {
                break
            }

            let piece = Self.extractPiece(result)
            generatedText += piece
        }

        return generatedText
    }

    // MARK: - Summary generation (concurrent with autocomplete)

    /// Generates a summary using an ephemeral sequence so the autocomplete cache is unaffected.
    /// The lifecycle guard prevents `shutdown()` from unloading the model while sampling is active.
    func summarize(
        prompt: String,
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

        let allPromptTokens = tokenize(prompt)
        guard !allPromptTokens.isEmpty else {
            throw LlamaRuntimeError.generationFailed("Tokenization returned no prompt tokens.")
        }

        let maxPromptTokens = max(1, preparedRuntime.contextWindowTokens - options.maxPredictionTokens)
        let promptTokens = allPromptTokens.count > maxPromptTokens
            ? Array(allPromptTokens.suffix(maxPromptTokens))
            : allPromptTokens

        let config = Self.samplingConfig(from: options)
        let seqID = engine.createSequence(config)
        guard seqID >= 0 else {
            throw LlamaRuntimeError.generationFailed("Unable to create summary sequence.")
        }
        defer { engine.destroySequence(seqID) }

        var tokens = promptTokens
        let status = engine.decodePrompt(seqID, &tokens, Int32(tokens.count), 0)
        guard status == .ok else {
            throw LlamaRuntimeError.generationFailed("Summary prompt decoding failed.")
        }

        var generatedText = ""
        for _ in 0 ..< options.maxPredictionTokens {
            // Cooperative cancellation: return partial text on timeout.
            if Task.isCancelled { break }

            let result = engine.sampleNext(seqID)
            if result.is_eos || result.was_cancelled { break }

            generatedText += Self.extractPiece(result)
        }

        return generatedText
    }

    // MARK: - Cache and lifecycle

    /// Drops the reusable autocomplete sequence while keeping the loaded model alive.
    func resetPromptCache() {
        autocompleteLock.lock()
        defer { autocompleteLock.unlock() }

        if autocompleteSequenceID >= 0 {
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
            seed: options.seed ?? 0
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
