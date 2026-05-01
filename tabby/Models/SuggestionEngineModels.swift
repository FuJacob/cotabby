import Foundation

/// File overview:
/// Defines the product-facing engine choices for Tabby's autocomplete pipeline.
/// This file exists because "which engine is active?" is a domain concept, not a UI-only detail.
///
/// The important architectural distinction is:
/// - a local GGUF file is a model option inside the llama runtime
/// - Apple Intelligence vs. local llama is an engine choice above the runtime layer
enum SuggestionEngineKind: String, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case appleIntelligence
    case llamaOpenSource

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .appleIntelligence:
            return "Apple Intelligence"
        case .llamaOpenSource:
            return "Open Source"
        }
    }

    /// These booleans let views render from capabilities instead of sprinkling engine-specific
    /// branches throughout the codebase.
    var supportsPromptModeSelection: Bool {
        switch self {
        case .appleIntelligence:
            return false
        case .llamaOpenSource:
            return true
        }
    }

    var supportsLocalModelManagement: Bool {
        switch self {
        case .appleIntelligence:
            return false
        case .llamaOpenSource:
            return true
        }
    }

    var supportedPromptModes: [SuggestionPromptMode] {
        switch self {
        case .appleIntelligence:
            return [.prefixOnly]
        case .llamaOpenSource:
            return SuggestionPromptMode.allCases
        }
    }

    var defaultPromptMode: SuggestionPromptMode {
        .prefixOnly
    }
}

/// A user-authored app blocklist entry.
///
/// The bundle identifier is the durable identity used by the suggestion pipeline. The display name
/// is saved only so Settings can show a readable list without having to resolve installed
/// applications again on every launch.
struct DisabledApplicationRule: Codable, Equatable, Identifiable, Sendable {
    let bundleIdentifier: String
    let displayName: String

    var id: String { bundleIdentifier }
}

/// A compact snapshot of the autocomplete settings the coordinator actually needs at generation
/// time. Keeping this as a value type makes change detection simple and deterministic.
struct SuggestionSettingsSnapshot: Equatable, Sendable {
    let isGloballyEnabled: Bool
    let disabledAppBundleIdentifiers: Set<String>
    let selectedEngine: SuggestionEngineKind
    let selectedWordCountPreset: SuggestionWordCountPreset
    let effectivePromptMode: SuggestionPromptMode
    /// Normalized user-authored guidance for the instructions-based completion style.
    /// This travels in the snapshot so generation uses the same value the Settings UI shows.
    let customAIInstructions: String?
    /// When true, the llama runtime applies `-inf` logit bias to known chat-residue tokens
    /// on the first generated token, preventing conversational openers from appearing in
    /// inline autocomplete suggestions.
    let isFirstTokenGatingEnabled: Bool
    /// When true, the llama runtime measures top-1 probability of the raw-logit softmax at
    /// position 0 and silently suppresses the suggestion if it falls below
    /// `firstTokenConfidenceThreshold`. Distinct from gating: gating *masks* specific tokens,
    /// confidence suppression *aborts* the whole suggestion when the model is uncertain.
    let isFirstTokenConfidenceGatingEnabled: Bool
    /// Probability threshold in [0, 1]. The suggestion is suppressed when the model's top-1
    /// raw-logit softmax probability at position 0 is below this value. 0 disables in practice
    /// (any probability >= 0 passes).
    let firstTokenConfidenceThreshold: Double
}
