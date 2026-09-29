import Foundation

/// Decides which suggestion engines a user may pick from an engine picker, and how each option is
/// labelled, given what this Mac can currently run.
///
/// Why this exists as its own type: onboarding (`WelcomeTemplateStepView`) and the power-profile
/// pickers already refuse Apple Intelligence when `FoundationModelAvailabilityService` reports it
/// unavailable, but the Settings and menu bar engine pickers listed every `SuggestionEngineKind`
/// unconditionally. Putting the rule in one pure `Support/` policy lets every picker share the same
/// answer and lets tests pin it without SwiftUI or a real `SystemLanguageModel`.
///
/// Scope: this gates *new* selections only. A previously persisted Apple Intelligence selection is
/// still honored as stored; the Settings callout and the engine's own `unavailable` error explain
/// why nothing is generated, and the choice comes back to life if Apple Intelligence becomes
/// available later (for example after its model finishes downloading).
enum SuggestionEngineSelectionPolicy {
    /// Whether `engine` may be chosen right now. Only Apple Intelligence depends on runtime
    /// availability; Open Source and the local endpoint are always selectable because their own
    /// panes guide the user through downloading a model or configuring a server.
    static func isSelectable(
        _ engine: SuggestionEngineKind,
        foundationModelAvailable: Bool
    ) -> Bool {
        switch engine {
        case .appleIntelligence:
            return foundationModelAvailable
        case .llamaOpenSource, .openAICompatible:
            return true
        }
    }

    /// The picker row text. Unselectable engines carry an "(Unavailable)" suffix so a greyed-out
    /// menu item still explains itself; the detailed reason stays in the pane callout.
    static func pickerLabel(
        for engine: SuggestionEngineKind,
        foundationModelAvailable: Bool
    ) -> String {
        guard isSelectable(engine, foundationModelAvailable: foundationModelAvailable) else {
            return "\(engine.displayLabel) (Unavailable)"
        }
        return engine.displayLabel
    }
}
