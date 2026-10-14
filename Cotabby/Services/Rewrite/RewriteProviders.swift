import Foundation

/// File overview:
/// The models a rewrite can run on, behind one narrow protocol so `RewriteEngine` chooses between
/// them without knowing how each talks to its model. `APIRewriteProvider` lives here; the Apple
/// Intelligence and Open Source providers are in `LocalRewriteProviders.swift`, the Local Endpoint
/// one in `LocalEndpointRewriteProvider.swift`, MLX in `MLXRewriteProvider.swift`.
@MainActor
protocol RewriteProviding: AnyObject {
    /// Whether this provider can run a rewrite right now (a model is configured and reachable in
    /// principle; network errors still surface as thrown errors).
    var isAvailable: Bool { get }
    /// Whether the text leaves this Mac (a LAN or public host), for the popup's disclosure.
    var sendsOffDevice: Bool { get }
    /// Why `isAvailable` is false, in words for the popup and Settings; nil when there is no
    /// specific reason.
    var unavailableReason: String? { get }
    /// The remote host the text goes to, for the disclosure; nil for providers on this Mac.
    var hostName: String? { get }
    /// Runs the rewrite. `onPartial` receives the cumulative raw text while it streams.
    func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String
}

extension RewriteProviding {
    var unavailableReason: String? { nil }
    var hostName: String? { nil }
}

/// Rewrites through the user's cloud service: Claude through Anthropic's Messages API
/// (`AnthropicMessagesClient`), every other service (OpenAI, Gemini, Mistral, Groq, OpenRouter, xAI,
/// DeepSeek, or a custom URL such as a self-hosted gateway or Ollama) through its OpenAI-compatible
/// endpoint. The service and its model come from `RewritePreferencesStore`; each service's key from
/// its own Keychain item (`RewriteCloudProvider.keychainSuffix`), so switching services keeps every
/// key and never touches autocomplete's endpoint. Owned by `RewriteEngine`.
@MainActor
final class APIRewriteProvider: RewriteProviding {
    static let timeout: TimeInterval = 20

    private let client: OpenAICompatibleAPIClient
    private let anthropic: AnthropicMessagesClient
    private let preferences: @MainActor () -> RewritePreferences
    private let credentials: @MainActor (RewriteCloudProvider) -> OpenAICompatibleCredentialStoring

    init(
        client: OpenAICompatibleAPIClient,
        anthropic: AnthropicMessagesClient,
        preferences: @escaping @MainActor () -> RewritePreferences,
        credentials: @escaping @MainActor (RewriteCloudProvider) -> OpenAICompatibleCredentialStoring
    ) {
        self.client = client
        self.anthropic = anthropic
        self.preferences = preferences
        self.credentials = credentials
    }

    nonisolated deinit {}

    /// Built fresh from the current preferences on every read, so a Settings edit takes effect on
    /// the next rewrite without a reload step. `try?` maps an invalid URL to nil, which reads as
    /// "not configured" rather than surfacing a parse error in the popup. Claude's URL is validated
    /// the same way; only the request format differs.
    private var configuration: OpenAICompatibleEndpointConfiguration? {
        let prefs = preferences()
        return try? OpenAICompatibleEndpointConfiguration(
            baseURLString: prefs.effectiveBaseURL, modelName: prefs.apiModelName, apiMode: .chatCompletions
        )
    }

    var isAvailable: Bool { configuration.map { !$0.modelName.isEmpty } ?? false }

    /// Anything that is not loopback counts as leaving the Mac, including LAN hosts, because the
    /// disclosure is about the text leaving this device, not about the internet.
    var sendsOffDevice: Bool { configuration.map { $0.hostScope != .loopback } ?? true }

    var hostName: String? { configuration?.baseURL.host }

    func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        guard let configuration, !configuration.modelName.isEmpty else { throw RewriteError.noProvider }
        let service = preferences().cloudProvider
        let apiKey = (try? credentials(service).readAPIKey())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Every named service needs a key, so say so before sending a request bound to fail with a
        // 401. A custom URL may legitimately need none (a local Ollama or a keyless gateway).
        if service != .custom, apiKey.isEmpty { throw RewriteError.missingAPIKey(service.displayName) }
        let prompt = RewritePromptBuilder.instructPrompt(request)
        if service == .anthropic {
            return try await anthropic.streamMessage(
                AnthropicMessage(model: configuration.modelName, system: prompt.system, user: prompt.user),
                baseURL: configuration.baseURL.absoluteString, apiKey: apiKey, timeout: Self.timeout, onPartial: onPartial
            )
        }
        return try await client.streamChat(
            configuration: configuration,
            apiKey: apiKey,
            messages: [.init(role: "system", content: prompt.system), .init(role: "user", content: prompt.user)],
            timeout: Self.timeout,
            onPartialRawText: onPartial
        )
    }
}

/// One Keychain store per cloud service, created on first use and kept for the app's lifetime.
/// Shared by the API provider (to read keys) and Settings → Rewrite (to save them).
@MainActor
final class RewriteCredentialVault {
    private var stores: [RewriteCloudProvider: KeychainOpenAICompatibleCredentialStore] = [:]

    nonisolated deinit {}

    func store(for service: RewriteCloudProvider) -> OpenAICompatibleCredentialStoring {
        if let store = stores[service] { return store }
        let store = KeychainOpenAICompatibleCredentialStore(serviceSuffix: service.keychainSuffix)
        stores[service] = store
        return store
    }
}

/// Loads the models a service offers for the Settings model picker: Claude through `GET /v1/models`,
/// the others through their OpenAI-compatible `/models`.
@MainActor
final class RewriteModelListService {
    private let client: OpenAICompatibleAPIClient
    private let anthropic: AnthropicMessagesClient

    init(client: OpenAICompatibleAPIClient, anthropic: AnthropicMessagesClient) {
        self.client = client
        self.anthropic = anthropic
    }

    nonisolated deinit {}

    func models(for service: RewriteCloudProvider, baseURL: String, apiKey: String?) async throws -> [String] {
        if service == .anthropic {
            return try await anthropic.listModels(baseURL: baseURL, apiKey: apiKey)
        }
        let configuration = try OpenAICompatibleEndpointConfiguration(baseURLString: baseURL, modelName: "", apiMode: .chatCompletions)
        return try await client.fetchModels(configuration: configuration, apiKey: apiKey).map(\.id)
    }
}
