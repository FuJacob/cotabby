import Foundation

/// File overview:
/// How Settings → Rewrite → Rewrite Model shows each choice: the row's title and whether it can be
/// picked, from the autocomplete engine's label and whether that row's provider can run. Pure, so the rules
/// (an unusable row stays visible but disabled; the default and the API row never are) are pinned by
/// tests instead of living only in a SwiftUI view. Used by `RewritePaneView`.
nonisolated enum RewriteProviderRowPolicy {
    /// "Same as autocomplete" names the engine it follows, or, when `sameAsAutocompleteStaysOnDevice`
    /// (autocomplete's endpoint is on another host), that it keeps rewrites on this Mac. An engine
    /// row whose provider cannot run right now says so.
    static func title(
        for kind: RewriteProviderKind,
        autocompleteEngineLabel: String,
        sameAsAutocompleteStaysOnDevice: Bool = false,
        isAvailable: Bool
    ) -> String {
        let label: String
        switch kind {
        case .sameAsAutocomplete:
            return sameAsAutocompleteStaysOnDevice
                ? "Same as autocomplete (on this Mac: your endpoint is not local)"
                : "Same as autocomplete (\(autocompleteEngineLabel))"
        case .api: return "API model"
        case .appleIntelligence: label = "Apple Intelligence"
        case .openSource: label = "Open Source"
        case .localEndpoint: label = "Local Endpoint"
        case .mlx: label = "MLX"
        }
        return isAvailable ? label : "\(label) (Unavailable)"
    }

    /// An unavailable engine row cannot be picked. "Same as autocomplete" and "API model" always can:
    /// the first is the default and shows its reason under the picker instead of trapping the user on
    /// another row; the API model is configured right there in the pane.
    static func isSelectable(_ kind: RewriteProviderKind, isAvailable: Bool) -> Bool {
        switch kind {
        case .sameAsAutocomplete, .api: return true
        case .appleIntelligence, .openSource, .localEndpoint, .mlx: return isAvailable
        }
    }
}
