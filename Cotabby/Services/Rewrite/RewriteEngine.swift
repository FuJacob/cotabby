import Foundation

/// File overview:
/// Runs one rewrite on the provider the user chose in Settings → Rewrite, and returns text ready to
/// replace the selection (`RewriteOutputCleaner`). "Same as autocomplete" is resolved here against
/// the current autocomplete engine (`RewriteProviderResolver`), so every decision (which provider
/// runs, what the disclosure names) is made on the concrete provider that will run. The default
/// never sends a rewrite off this Mac on its own: with autocomplete on an endpoint on another host
/// it resolves to the on-device fallback. The single
/// place that maps the preference to a provider, so the coordinator, the popup's disclosure and the
/// Settings pane always agree on where the text goes. Built by `CotabbyAppEnvironment`, used by
/// `SelectionRewriteCoordinator` and the Rewrite pane.
@MainActor
final class RewriteEngine {
    private let appleIntelligence: RewriteProviding
    private let openSource: RewriteProviding
    private let localEndpoint: RewriteProviding
    private let mlx: RewriteProviding
    private let api: RewriteProviding
    private let autocompleteEngine: @MainActor () -> SuggestionEngineKind
    private let endpointHostScope: @MainActor () -> OpenAICompatibleHostScope?
    private let preferences: @MainActor () -> RewritePreferences

    init(
        appleIntelligence: RewriteProviding,
        openSource: RewriteProviding,
        localEndpoint: RewriteProviding,
        mlx: RewriteProviding,
        api: RewriteProviding,
        autocompleteEngine: @escaping @MainActor () -> SuggestionEngineKind,
        endpointHostScope: @escaping @MainActor () -> OpenAICompatibleHostScope?,
        preferences: @escaping @MainActor () -> RewritePreferences
    ) {
        self.appleIntelligence = appleIntelligence
        self.openSource = openSource
        self.localEndpoint = localEndpoint
        self.mlx = mlx
        self.api = api
        self.autocompleteEngine = autocompleteEngine
        self.endpointHostScope = endpointHostScope
        self.preferences = preferences
    }

    nonisolated deinit {}

    /// The concrete provider kind the current choice runs on; never `sameAsAutocomplete`. Read per
    /// rewrite rather than cached, so a change in Settings applies to the next one.
    var resolvedKind: RewriteProviderKind { resolve(preferences().provider) }

    /// True while "Same as autocomplete" runs on this Mac because autocomplete's endpoint is on
    /// another host. The Settings row and its note say so.
    var sameAsAutocompleteStaysOnDevice: Bool {
        RewriteProviderResolver.sameAsAutocompleteStaysOnDevice(
            autocompleteEngine: autocompleteEngine(), endpointHostScope: endpointHostScope())
    }

    private func resolve(_ kind: RewriteProviderKind) -> RewriteProviderKind {
        RewriteProviderResolver.resolve(
            kind,
            autocompleteEngine: autocompleteEngine(),
            endpointHostScope: endpointHostScope(),
            appleIntelligenceAvailable: appleIntelligence.isAvailable
        )
    }

    /// The provider for a kind (`sameAsAutocomplete` is resolved first). The Settings pane asks it
    /// for availability and the reason a row is disabled.
    func provider(for kind: RewriteProviderKind) -> RewriteProviding {
        switch resolve(kind) {
        case .appleIntelligence: return appleIntelligence
        case .openSource: return openSource
        case .localEndpoint: return localEndpoint
        case .mlx: return mlx
        case .api: return api
        case .sameAsAutocomplete: return openSource // unreachable: the resolver never returns it
        }
    }

    var activeProvider: RewriteProviding { provider(for: resolvedKind) }

    /// Resolves the current choice once, for a popup to disclose and then run every rewrite on.
    func destination() -> RewriteDestination {
        let kind = resolvedKind
        let provider = provider(for: kind)
        return RewriteDestination(kind: kind, sendsOffDevice: provider.sendsOffDevice, hostName: provider.hostName)
    }

    /// Rewrites on the current choice (resolved now).
    func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        try await rewrite(request, to: destination(), onPartial: onPartial)
    }

    /// Rewrites on `destination`, the one a popup resolved and disclosed. If its provider would now
    /// send the text somewhere else (the endpoint's URL was edited meanwhile), nothing is sent.
    func rewrite(
        _ request: RewriteRequest,
        to destination: RewriteDestination,
        onPartial: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        guard request.selection.count <= SelectionRewriteEligibility.maximumCharacters else { throw RewriteError.selectionTooLong }
        let provider = provider(for: destination.kind)
        guard provider.sendsOffDevice == destination.sendsOffDevice, provider.hostName == destination.hostName else {
            throw RewriteError.destinationChanged
        }
        guard provider.isAvailable else {
            if let reason = provider.unavailableReason { throw RewriteError.unavailable(reason) }
            throw RewriteError.noProvider
        }
        let raw = try await provider.rewrite(request, onPartial: onPartial)
        guard let cleaned = RewriteOutputCleaner.clean(raw, selection: request.selection, action: request.action) else {
            throw RewriteError.unusableOutput
        }
        return cleaned
    }
}
