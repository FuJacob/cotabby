import Foundation
import Logging

/// Adapts an OpenAI-compatible SSE stream to Cotabby's backend-independent suggestion contract.
/// The HTTP client owns wire parsing; this type owns sampling, normalization, logging, and error
/// mapping so the router never needs endpoint-specific behavior. One type serves two backends: the
/// user's endpoint, and the loopback `mlx_lm.server` that the MLX engine runs (`Backend`).
@MainActor
final class OpenAICompatibleSuggestionEngine: SuggestionGenerating {
    /// Which server this instance talks to. The endpoint instance sends only OpenAI's basics. The
    /// MLX instance adds mlx_lm.server's sampling fields and ends the stream itself at a sentence
    /// end, the way the llama runtime stops decoding (`DecodeStopPolicy`).
    enum Backend: Equatable {
        case endpoint
        case mlx

        var logLabel: String { self == .mlx ? "mlx" : "openai_compatible" }
    }

    private let client: OpenAICompatibleAPIClient
    private let configurationProvider: @MainActor () throws -> OpenAICompatibleEndpointConfiguration
    private let apiKeyProvider: @MainActor () throws -> String?
    /// Owned for the engine's lifetime so focus-scoped warmup calls share one in-flight model load.
    private let preloadWorkController = OllamaPreloadWorkController()
    private let backend: Backend
    /// MLX only: told the port and a short reason when a request shows the server's generator died
    /// (see `MLXGeneratorFailure`). The endpoint backend never calls it.
    private let onServerBroken: (@MainActor (Int, String) -> Void)?
    /// Confirms a suspicious 404 against the server's `/health` before reporting it broken.
    private let healthCheck: MLXHealthCheck

    init(
        client: OpenAICompatibleAPIClient,
        configurationProvider: @escaping @MainActor () throws -> OpenAICompatibleEndpointConfiguration,
        apiKeyProvider: @escaping @MainActor () throws -> String?,
        backend: Backend = .endpoint,
        onServerBroken: (@MainActor (Int, String) -> Void)? = nil,
        healthCheck: @escaping MLXHealthCheck = MLXHealthProbe.check(port:)
    ) {
        self.client = client
        self.configurationProvider = configurationProvider
        self.apiKeyProvider = apiKeyProvider
        self.backend = backend
        self.onServerBroken = onServerBroken
        self.healthCheck = healthCheck
    }

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        try await generateSuggestion(for: request, onPartial: nil)
    }

    func generateSuggestion(
        for request: SuggestionRequest,
        onPartial: (@MainActor (SuggestionResult) -> Void)?
    ) async throws -> SuggestionResult {
        let metadata: Logger.Metadata = [
            "request_id": .string(request.requestID),
            "engine": .string(backend.logLabel)
        ]
        let startTime = Date()
        // Set once the configuration resolves, so the catch below knows which server failed.
        var serverPort: Int?
        do {
            let configuration = try configurationProvider()
            serverPort = configuration.baseURL.port
            let apiKey = try apiKeyProvider()
            let partialHandler: (@MainActor (String) -> Void)?
            if let onPartial {
                partialHandler = { @MainActor cumulativeRaw in
                    let normalized = SuggestionTextNormalizer.normalizeDetailed(cumulativeRaw, for: request).text
                    guard !normalized.isEmpty else { return }
                    onPartial(SuggestionResult(
                        generation: request.generation,
                        rawText: cumulativeRaw,
                        text: normalized,
                        latency: Date().timeIntervalSince(startTime)
                    ))
                }
            } else {
                partialHandler = nil
            }

            CotabbyLogger.suggestion.debug(
                "OpenAI-compatible endpoint generating",
                metadata: metadata.merging([
                    "model": .string(configuration.modelName),
                    "api_mode": .string(configuration.apiMode.rawValue),
                    "prompt_bytes": .stringConvertible(request.prompt.utf8.count),
                    "max_tokens": .stringConvertible(request.maxPredictionTokens)
                ]) { _, new in new }
            )

            let raw = try await client.generate(
                configuration: configuration,
                apiKey: apiKey,
                prompt: request.prompt,
                options: OpenAICompatibleGenerationOptions(
                    maxPredictionTokens: request.maxPredictionTokens,
                    temperature: request.temperature,
                    topP: request.topP,
                    mlx: backend == .mlx ? Self.mlxOptions(for: request) : nil
                ),
                onPartialRawText: partialHandler,
                stopWhen: backend == .mlx ? Self.earlyStop(for: request) : nil
            )
            try Task.checkCancellation()

            let normalization = SuggestionTextNormalizer.normalizeDetailed(raw, for: request)
            let latency = Date().timeIntervalSince(startTime)
            let latencyMs = Int((latency * 1_000).rounded())
            let suppression = normalization.suppression?.rawValue ?? "none"
            CotabbyLogger.suggestion.debug(
                "OpenAI-compatible endpoint generated",
                metadata: metadata.merging([
                    "model": .string(configuration.modelName),
                    "raw_chars": .stringConvertible(raw.count),
                    "normalized_chars": .stringConvertible(normalization.text.count),
                    "suppression_reason": .string(suppression),
                    "latency_ms": .stringConvertible(latencyMs)
                ]) { _, new in new }
            )
            CotabbyLogger.llmIO.debug(
                "OpenAI-compatible endpoint generation",
                metadata: metadata.merging([
                    "model": .string(configuration.modelName),
                    "prompt": .string(request.prompt),
                    "completion_raw": .string(raw),
                    "completion_normalized": .string(normalization.text),
                    "suppression_reason": .string(suppression),
                    "latency_ms": .stringConvertible(latencyMs)
                ]) { _, new in new }
            )
            return SuggestionResult(
                generation: request.generation,
                rawText: raw,
                text: normalization.text,
                latency: latency,
                suppressionReason: normalization.suppression?.rawValue
            )
        } catch is CancellationError {
            CotabbyLogger.suggestion.debug("Endpoint generation cancelled", metadata: metadata)
            throw SuggestionClientError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            CotabbyLogger.suggestion.debug("Endpoint request cancelled", metadata: metadata)
            throw SuggestionClientError.cancelled
        } catch let error as OpenAICompatibleClientError
            where backend == .mlx && MLXGeneratorFailure.reason(for: error) != nil {
            // Looks like a dead generator, but mlx_lm answers 404 for per-request failures too.
            // `/health` decides: healthy means this one request failed and the server stays.
            guard let serverPort, let reason = MLXGeneratorFailure.reason(for: error) else {
                throw SuggestionClientError.generationFailed(error.localizedDescription)
            }
            let health = await healthCheck(serverPort)
            // The user kept typing while the probe ran: its answer (a cancelled request looks like
            // "unreachable") says nothing about the server, so never restart it for this.
            if Task.isCancelled || health == .cancelled { throw SuggestionClientError.cancelled }
            guard health != .healthy else {
                CotabbyLogger.suggestion.error(
                    "MLX request failed but the server is healthy: \(reason)", metadata: metadata)
                throw SuggestionClientError.generationFailed(error.localizedDescription)
            }
            CotabbyLogger.suggestion.error("MLX generator failed: \(reason)", metadata: metadata)
            onServerBroken?(serverPort, reason)
            throw SuggestionClientError.unavailable("MLX is restarting…")
        } catch let error as SuggestionClientError {
            // The MLX configuration provider reports "server not ready" this way, already phrased
            // for the user; wrapping it again would turn it into a generic generation failure.
            throw error
        } catch let error as OpenAICompatibleEndpointError {
            throw SuggestionClientError.unavailable(error.localizedDescription)
        } catch {
            CotabbyLogger.suggestion.error(
                "OpenAI-compatible endpoint failed: \(error.localizedDescription)",
                metadata: metadata
            )
            throw SuggestionClientError.generationFailed(error.localizedDescription)
        }
    }

    func resetCachedGenerationContext() async {}

    /// Same sampling values the llama runtime uses, so MLX and Open Source condition alike.
    private static func mlxOptions(for request: SuggestionRequest) -> MLXCompletionOptions {
        MLXCompletionOptions(
            topK: request.topK,
            minP: request.minP,
            repetitionPenalty: request.repetitionPenalty,
            seed: request.randomSeed.map(Int.init),
            stop: request.isMultiLineEnabled ? [] : ["\n"]
        )
    }

    /// The llama runtime's stop rule applied to the streamed text: one SSE text event is about one
    /// token, which is what `tokensGenerated` counts for the minimum-token guard.
    private static func earlyStop(for request: SuggestionRequest) -> @MainActor (String, Int) -> Bool {
        let minimumWords = request.wordRange?.lowWords ?? 0
        return { accumulated, events in
            DecodeStopPolicy.verdict(
                accumulated: accumulated,
                tokensGenerated: events,
                minimumWords: minimumWords
            ) != nil
        }
    }

    /// Best-effort Ollama cold-start work runs through a request that is independent from the
    /// coordinator's cancellable prediction task. Typing again can therefore discard stale
    /// autocomplete work without aborting the model load that future requests need.
    func prewarm(for _: SuggestionRequest) async {
        // The Ollama preload path is endpoint-only; the MLX instance warms up in its server manager.
        guard backend == .endpoint else { return }
        do {
            let configuration = try configurationProvider()
            guard configuration.defaultOllamaGenerateURL != nil else { return }
            let apiKey = try apiKeyProvider()
            await preloadWorkController.run(modelName: configuration.modelName) { [client] in
                do {
                    _ = try await client.preloadDefaultOllamaModel(
                        configuration: configuration,
                        apiKey: apiKey
                    )
                    CotabbyLogger.runtime.info(
                        "Preloaded default Ollama model",
                        metadata: ["model": .string(configuration.modelName)]
                    )
                } catch is CancellationError {
                    // App shutdown may cancel opportunistic work; warmup never becomes user-facing.
                } catch {
                    CotabbyLogger.runtime.warning(
                        "Default Ollama model preload failed: \(error.localizedDescription)"
                    )
                }
            }
        } catch {
            CotabbyLogger.runtime.warning(
                "Default Ollama preload configuration failed: \(error.localizedDescription)"
            )
        }
    }
}

/// Coalesces focus-driven Ollama warmups without coupling them to prediction cancellation.
///
/// `OpenAICompatibleSuggestionEngine` owns one controller for its full lifetime. The first caller
/// for a model creates the load task; later focus changes await that task instead of queuing more
/// `/api/generate` requests. Completed work is removed so a later focus can retry after Ollama has
/// restarted. The flight ID prevents an older waiter from deleting a newer retry for the same model.
@MainActor
final class OllamaPreloadWorkController {
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var flightsByModel: [String: Flight] = [:]

    func run(
        modelName: String,
        operation: @escaping @MainActor () async -> Void
    ) async {
        if let existing = flightsByModel[modelName] {
            await existing.task.value
            return
        }

        let id = UUID()
        // This unstructured task deliberately outlives cancellation of any one focus caller. Model
        // loading is shared infrastructure; tying it to a stale field would recreate the 499 abort.
        let task = Task { @MainActor in
            await operation()
        }
        flightsByModel[modelName] = Flight(id: id, task: task)
        await task.value

        guard flightsByModel[modelName]?.id == id else { return }
        flightsByModel[modelName] = nil
    }
}
