import Foundation

/// File overview:
/// Pure decision for which `SettingsCategory` rows in the redesigned Settings sidebar should
/// render an attention dot.
///
/// Why this lives in `Support/`:
/// The legacy settings window puts a single attention banner at the top of one giant form. The
/// redesign surfaces attention per pane: a sidebar dot signals "look in here," and the affected
/// Keeping the rule outside the view layer makes it unit-testable without AppKit and keeps the
/// sidebar view free of state-mapping logic.
enum SettingsAttentionEvaluator {
    /// Snapshot of the app state the evaluator inspects. Keeping inputs as a flat value type means
    /// callers can build it from whatever observables they hold without dragging the model graph
    /// into the helper. A future "no models found" attention can be added without breaking
    /// callers because new fields default at the call site.
    struct Inputs: Equatable {
        let permissionsGranted: Bool
        let selectedEngine: SuggestionEngineKind
        let foundationModelAvailable: Bool
        let llamaRuntimeFailedReason: String?
        let endpointConfigurationError: String?
        let endpointConnectionFailedReason: String?
    }

    /// Returns the set of categories that should render an attention dot in the sidebar.
    static func categoriesNeedingAttention(_ inputs: Inputs) -> Set<SettingsCategory> {
        var categories: Set<SettingsCategory> = []

        if !inputs.permissionsGranted {
            categories.insert(.permissions)
        }

        switch inputs.selectedEngine {
        case .appleIntelligence:
            if !inputs.foundationModelAvailable {
                categories.insert(.engineAndModel)
            }
        case .llamaOpenSource:
            if inputs.llamaRuntimeFailedReason != nil {
                categories.insert(.engineAndModel)
            }
        case .openAICompatible:
            if inputs.endpointConfigurationError != nil || inputs.endpointConnectionFailedReason != nil {
                categories.insert(.engineAndModel)
            }
        }

        return categories
    }

}
