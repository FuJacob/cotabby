import Foundation

/// File overview:
/// Rewrites on the OpenAI-compatible endpoint the user set up for autocomplete (Ollama, LM Studio,
/// vLLM, a gateway), with the same model name and API key. There is no rewrite-only endpoint or
/// model: Settings → Rewrite → "Local Endpoint" reuses Settings → Engine & Model.
///
/// The endpoint's API mode decides the prompt shape. A chat endpoint gets the instruct prompt as
/// system and user messages (`streamChat`). A completions endpoint serves a base model, so it gets
/// the base prompt with the example, the rewrite stop sequences and a token budget sized from the
/// selection (`generate`). The text leaves this Mac when the host is not loopback, which is what
/// `sendsOffDevice` and `hostName` report for the popup's and the Settings pane's disclosure.
/// Owned by `RewriteEngine`; the configuration and key are read per rewrite through closures, so a
/// Settings edit takes effect on the next rewrite.
@MainActor
final class LocalEndpointRewriteProvider: RewriteProviding {
    static let timeout: TimeInterval = 60

    private let client: OpenAICompatibleAPIClient
    private let configurationProvider: @MainActor () throws -> OpenAICompatibleEndpointConfiguration
    private let apiKeyProvider: @MainActor () throws -> String?

    init(
        client: OpenAICompatibleAPIClient,
        configuration: @escaping @MainActor () throws -> OpenAICompatibleEndpointConfiguration,
        apiKey: @escaping @MainActor () throws -> String?
    ) {
        self.client = client
        self.configurationProvider = configuration
        self.apiKeyProvider = apiKey
    }

    nonisolated deinit {}

    /// `try?` maps an invalid URL to nil, which reads as "not configured" rather than surfacing a
    /// parse error in the popup (the same choice as `APIRewriteProvider`).
    private var configuration: OpenAICompatibleEndpointConfiguration? { try? configurationProvider() }

    var isAvailable: Bool { configuration.map { !$0.modelName.isEmpty } ?? false }

    /// Anything but loopback counts as leaving the Mac, including LAN hosts: the disclosure is about
    /// the text leaving this device, not about the internet.
    var sendsOffDevice: Bool { configuration.map { $0.hostScope != .loopback } ?? true }

    var hostName: String? { configuration?.baseURL.host }

    var unavailableReason: String? {
        guard !isAvailable else { return nil }
        return configuration == nil
            ? "The Local Endpoint isn't set up. Configure it in Settings → Engine & Model."
            : "The Local Endpoint has no model. Choose one in Settings → Engine & Model."
    }

    func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        guard let configuration, !configuration.modelName.isEmpty else { throw RewriteError.noProvider }
        let apiKey = try? apiKeyProvider()
        switch configuration.apiMode {
        case .chatCompletions:
            let prompt = RewritePromptBuilder.instructPrompt(request)
            return try await client.streamChat(
                configuration: configuration,
                apiKey: apiKey,
                messages: [.init(role: "system", content: prompt.system), .init(role: "user", content: prompt.user)],
                timeout: Self.timeout,
                onPartialRawText: onPartial
            )
        case .completions:
            return try await Self.generateBase(
                client: client, configuration: configuration, apiKey: apiKey, request: request, onPartial: onPartial)
        }
    }

    /// A base-model rewrite on a completions route, shared with the MLX provider. The `stop` field
    /// asks the server to end before the next example, but not every server honours it, and one
    /// that does may still stream part of a stop sequence before it matches; the text is cut at the
    /// first stop sequence either way, in every partial and in the result, so "Draft:" never
    /// reaches the preview or the field (the same cut the llama path makes).
    static func generateBase(
        client: OpenAICompatibleAPIClient,
        configuration: OpenAICompatibleEndpointConfiguration,
        apiKey: String?,
        request: RewriteRequest,
        onPartial: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let output = try await client.generate(
            configuration: configuration,
            apiKey: apiKey,
            prompt: RewritePromptBuilder.basePrompt(request),
            options: completionOptions(for: request),
            onPartialRawText: { onPartial(RewritePromptBuilder.cutAtBaseStop($0)) }
        )
        return RewritePromptBuilder.cutAtBaseStop(output)
    }

    /// Sampling for a base-model rewrite, shared with the MLX provider's base path: a low
    /// temperature like the llama path, the rewrite stop sequences, and `tokenBudget`.
    static func completionOptions(for request: RewriteRequest) -> OpenAICompatibleGenerationOptions {
        OpenAICompatibleGenerationOptions(
            maxPredictionTokens: RewritePromptBuilder.tokenBudget(request),
            temperature: 0.3, topP: 0.9, stop: RewritePromptBuilder.baseStopSequences
        )
    }
}
