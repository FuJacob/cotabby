import Foundation

/// File overview:
/// Pure decision for which `SettingsCategory` rows in the redesigned Settings sidebar should
/// render an attention dot, and what callout (if any) belongs at the top of that pane.
///
/// Why this lives in `Support/`:
/// The legacy settings window puts a single attention banner at the top of one giant form. The
/// redesign surfaces attention per pane: a sidebar dot signals "look in here," and the affected
/// pane carries an inline callout next to the controls that fix the underlying problem. Keeping
/// the rule outside the view layer makes it unit-testable without AppKit and keeps the sidebar
/// view free of state-mapping logic.
enum SettingsAttentionEvaluator {
    /// Snapshot of the app state the evaluator inspects. Keeping inputs as a flat value type means
    /// callers can build it from whatever observables they hold without dragging the model graph
    /// into the helper. A future "no models found" attention can be added without breaking
    /// callers because new fields default at the call site.
    struct Inputs: Equatable {
        let permissionsGranted: Bool
        let selectedEngine: SuggestionEngineKind
        let foundationModelAvailable: Bool
        let foundationModelMessage: String
        let llamaRuntimeFailedReason: String?
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
        }

        return categories
    }

    /// Returns the callout that belongs at the top of `category`'s pane, or `nil` if the pane is
    /// healthy. Each pane already owns its own callout binding today; centralizing the message
    /// keeps the wording consistent across the sidebar dot tooltip and the pane callout, and
    /// makes a future copy-edit a one-file change.
    static func calloutMessage(for category: SettingsCategory, inputs: Inputs) -> String? {
        switch category {
        case .permissions:
            guard !inputs.permissionsGranted else { return nil }
            return "Cotabby needs more access to run. Grant the permissions below to enable autocomplete."

        case .engineAndModel:
            switch inputs.selectedEngine {
            case .appleIntelligence:
                guard !inputs.foundationModelAvailable,
                      !inputs.foundationModelMessage.isEmpty else { return nil }
                return inputs.foundationModelMessage
            case .llamaOpenSource:
                guard let reason = inputs.llamaRuntimeFailedReason,
                      !reason.isEmpty else { return nil }
                return reason
            }

        case .home, .general, .appearance, .emoji, .writing, .context, .shortcuts, .apps, .performance, .about:
            return nil
        }
    }
}
