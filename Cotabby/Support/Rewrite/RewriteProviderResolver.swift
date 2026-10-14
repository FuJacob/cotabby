import Foundation

/// File overview:
/// Turns the user's Rewrite Model choice into the concrete provider that will run. Pure and
/// stateless so the rules are testable without engines, settings or MainActor state. Used by
/// `RewriteEngine` (which provider runs), the Rewrite settings pane (which row is active, what it
/// says) and the environment (whether Rewrite's on-demand MLX server is still wanted).
///
/// "Same as autocomplete" follows the autocomplete engine, with one exception that protects
/// privacy: it never sends a rewrite off this Mac on its own. Autocomplete on an OpenAI-compatible
/// endpoint on another host (LAN or public) means the user chose that host for suggestions, not
/// for rewriting whole selections, so the default stays on-device there (Apple Intelligence when
/// available, else Open Source). Choosing "Local Endpoint" explicitly still sends it, with the
/// disclosure.
nonisolated enum RewriteProviderResolver {
    /// `endpointHostScope` is the scope of autocomplete's endpoint, nil when it is not configured
    /// (a rewrite there sends nothing and reports why). `appleIntelligenceAvailable` picks the
    /// on-device fallback. The result is never `sameAsAutocomplete`.
    static func resolve(
        _ kind: RewriteProviderKind,
        autocompleteEngine: SuggestionEngineKind,
        endpointHostScope: OpenAICompatibleHostScope?,
        appleIntelligenceAvailable: Bool
    ) -> RewriteProviderKind {
        guard kind == .sameAsAutocomplete else { return kind }
        switch autocompleteEngine {
        case .appleIntelligence: return .appleIntelligence
        case .llamaOpenSource: return .openSource
        case .mlx: return .mlx
        case .openAICompatible:
            guard sameAsAutocompleteStaysOnDevice(autocompleteEngine: autocompleteEngine, endpointHostScope: endpointHostScope)
            else { return .localEndpoint }
            return appleIntelligenceAvailable ? .appleIntelligence : .openSource
        }
    }

    /// True when "Same as autocomplete" runs on this Mac instead of autocomplete's engine, because
    /// that engine is an endpoint on another host. The Settings row says so.
    static func sameAsAutocompleteStaysOnDevice(
        autocompleteEngine: SuggestionEngineKind,
        endpointHostScope: OpenAICompatibleHostScope?
    ) -> Bool {
        guard autocompleteEngine == .openAICompatible, let endpointHostScope else { return false }
        return endpointHostScope != .loopback
    }

    /// Whether a choice runs on MLX. It depends only on the choice and the autocomplete engine (the
    /// on-device fallback is never MLX), so the environment's MLX-server observer needs no more.
    static func usesMLX(_ kind: RewriteProviderKind, autocompleteEngine: SuggestionEngineKind) -> Bool {
        kind == .mlx || (kind == .sameAsAutocomplete && autocompleteEngine == .mlx)
    }
}
