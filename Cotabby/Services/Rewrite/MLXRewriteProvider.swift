import Foundation

/// File overview:
/// Rewrites with the MLX model autocomplete uses, on whichever server can serve it. There is no
/// rewrite-only model: the model is `suggestionSettings.mlxModelID`.
///
/// - If autocomplete is on MLX, the rewrite always goes to autocomplete's server and never starts
///   another one: a second copy of the same weights would double the memory the user chose to
///   spend once. While that server is starting (launch, model change, a restart after a broken
///   generator) the rewrite waits for it; if it failed or is off, the rewrite fails with its reason.
/// - Only when autocomplete is not on MLX does the on-demand `MLXRewriteServerController` start a
///   server on the same model (the first rewrite after idle takes ~10 s) and stop it after it has
///   been idle for a while.
///
/// The prompt follows the model: an instruct or chat model (`MLXModelCompatibility.isInstructName`)
/// gets the instruct prompt through `streamChat`; a base model gets the base prompt with the example
/// through the completions route, with the rewrite stop sequences and a budget from the selection.
/// Weaker on base models, which the Settings pane says. The server listens on 127.0.0.1 only, so
/// `sendsOffDevice` is false. A 404 that `/health` confirms as a dead generator is reported, like
/// the MLX engine does, to whichever server served the request. Owned by `RewriteEngine`.
@MainActor
final class MLXRewriteProvider: RewriteProviding {
    static let timeout: TimeInterval = 60
    /// Shown in the popup while the on-demand server starts; the first streamed token replaces it.
    static let loadingNote = "Loading MLX model…"

    private let controller: MLXRewriteServerController
    private let autocompleteServer: MLXServerManager
    private let autocompleteEngine: @MainActor () -> SuggestionEngineKind
    private let modelID: @MainActor () -> String
    private let client: OpenAICompatibleAPIClient
    private let healthCheck: MLXHealthCheck
    private let sleep: MLXRewriteServerController.Sleep

    init(
        controller: MLXRewriteServerController,
        autocompleteServer: MLXServerManager,
        autocompleteEngine: @escaping @MainActor () -> SuggestionEngineKind,
        modelID: @escaping @MainActor () -> String,
        client: OpenAICompatibleAPIClient,
        healthCheck: @escaping MLXHealthCheck = MLXHealthProbe.check(port:),
        sleep: @escaping MLXRewriteServerController.Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.controller = controller
        self.autocompleteServer = autocompleteServer
        self.autocompleteEngine = autocompleteEngine
        self.modelID = modelID
        self.client = client
        self.healthCheck = healthCheck
        self.sleep = sleep
    }

    nonisolated deinit {}

    /// Autocomplete is on MLX, so its server (not the on-demand one) serves rewrites.
    private var followsAutocompleteServer: Bool { autocompleteEngine() == .mlx }

    /// Autocomplete's server endpoint when it is ready on the model the settings name.
    private var readyAutocompleteConfiguration: OpenAICompatibleEndpointConfiguration? {
        guard followsAutocompleteServer, case .ready(_, let model) = autocompleteServer.state,
              model == (MLXRepoID(modelID())?.value ?? modelID()) else { return nil }
        return try? autocompleteServer.readyConfiguration
    }

    /// With autocomplete on MLX: its server is ready, or on its way (starting or stopping), so a
    /// rewrite can wait. Otherwise: Apple Silicon with mlx-lm ready and the model downloaded and
    /// compatible, exactly when the on-demand server could start.
    var isAvailable: Bool {
        guard followsAutocompleteServer else { return controller.canRun(modelID: modelID()) }
        switch autocompleteServer.state {
        case .ready, .starting, .stopping: return true
        case .idle, .unavailable, .failed: return false
        }
    }

    var sendsOffDevice: Bool { false }

    var unavailableReason: String? {
        guard followsAutocompleteServer else { return controller.unavailableReason(modelID: modelID()) }
        return isAvailable ? nil : autocompleteServer.state.notReadyMessage
    }

    func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        if followsAutocompleteServer {
            if let ready = readyAutocompleteConfiguration {
                return try await send(request, to: ready, server: autocompleteServer, onPartial: onPartial)
            }
            // Autocomplete's server is loading: say so, then wait for it. Nothing is launched here.
            onPartial(Self.loadingNote)
            let configuration = try await autocompleteServer.waitUntilReady(
                modelID: MLXRepoID(modelID())?.value ?? modelID(),
                timeout: MLXRewriteServerController.defaultReadyTimeout, sleep: sleep)
            return try await send(request, to: configuration, server: autocompleteServer, onPartial: onPartial)
        }
        // Always sent first: the popup would otherwise sit on "Rewriting…" for the whole start-up,
        // and the first streamed token replaces it. It is never part of the returned text.
        onPartial(Self.loadingNote)
        // Counted as in flight so the idle timer cannot stop the server under a running rewrite.
        controller.beginUse()
        defer { controller.endUse() }
        let configuration = try await controller.readyConfiguration(modelID: modelID())
        return try await send(request, to: configuration, server: controller.manager, onPartial: onPartial)
    }

    /// Streams the rewrite to `configuration`'s server, shaped for the model that server runs.
    private func send(
        _ request: RewriteRequest,
        to configuration: OpenAICompatibleEndpointConfiguration,
        server: MLXServerManager,
        onPartial: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        do {
            if Self.isInstruct(modelID: configuration.modelName) {
                let prompt = RewritePromptBuilder.instructPrompt(request)
                return try await client.streamChat(
                    configuration: configuration,
                    apiKey: nil,
                    messages: [.init(role: "system", content: prompt.system), .init(role: "user", content: prompt.user)],
                    timeout: Self.timeout,
                    onPartialRawText: onPartial
                )
            }
            return try await LocalEndpointRewriteProvider.generateBase(
                client: client, configuration: configuration, apiKey: nil, request: request, onPartial: onPartial)
        } catch let error as OpenAICompatibleClientError {
            // A 404 may mean the generator died or just that this request failed; `/health` decides.
            if let reason = MLXGeneratorFailure.reason(for: error), let port = configuration.baseURL.port {
                let health = await healthCheck(port)
                // A cancelled rewrite says nothing about the server (the MLX engine has the same guard).
                if Task.isCancelled || health == .cancelled { throw CancellationError() }
                guard health != .healthy else { throw error }
                server.reportBroken(port: port, reason: reason)
                throw RewriteError.unavailable("MLX is restarting…")
            }
            throw error
        }
    }

    /// Whether the repo name ("gemma-4-e4b-it-4bit" in "org/gemma-4-e4b-it-4bit") marks an
    /// instruction-following model. Unknown names count as base: the base prompt works on both,
    /// the instruct prompt only on chat-tuned models.
    static func isInstruct(modelID: String) -> Bool {
        let name = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return MLXModelCompatibility.isInstructName(name)
    }
}
