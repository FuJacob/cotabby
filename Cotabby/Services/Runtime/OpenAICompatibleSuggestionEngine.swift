import Foundation
import Logging

/// Adapts an OpenAI-compatible SSE stream to Cotabby's backend-independent suggestion contract.
/// The HTTP client owns wire parsing; this type owns sampling, normalization, logging, and error
/// mapping so the router never needs endpoint-specific behavior.
@MainActor
final class OpenAICompatibleSuggestionEngine: SuggestionGenerating {
    private let client: OpenAICompatibleAPIClient
    private let configurationProvider: @MainActor () throws -> OpenAICompatibleEndpointConfiguration
    private let apiKeyProvider: @MainActor () throws -> String?

    init(
        client: OpenAICompatibleAPIClient,
        configurationProvider: @escaping @MainActor () throws -> OpenAICompatibleEndpointConfiguration,
        apiKeyProvider: @escaping @MainActor () throws -> String?
    ) {
        self.client = client
        self.configurationProvider = configurationProvider
        self.apiKeyProvider = apiKeyProvider
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
            "engine": .string("openai_compatible")
        ]
        let startTime = Date()
        do {
            let configuration = try configurationProvider()
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
                    topP: request.topP
                ),
                onPartialRawText: partialHandler
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

    /// Best-effort Ollama cold-start work runs through a request that is independent from the
    /// coordinator's cancellable prediction task. Typing again can therefore discard stale
    /// autocomplete work without aborting the model load that future requests need.
    func prewarm(for _: SuggestionRequest) async {
        do {
            let configuration = try configurationProvider()
            let didPreload = try await client.preloadDefaultOllamaModel(
                configuration: configuration,
                apiKey: try apiKeyProvider()
            )
            guard didPreload else { return }
            CotabbyLogger.runtime.info(
                "Preloaded default Ollama model",
                metadata: ["model": .string(configuration.modelName)]
            )
        } catch is CancellationError {
            // App shutdown may cancel this opportunistic work; warmup never becomes user-facing.
        } catch {
            CotabbyLogger.runtime.warning(
                "Default Ollama model preload failed: \(error.localizedDescription)"
            )
        }
    }
}
