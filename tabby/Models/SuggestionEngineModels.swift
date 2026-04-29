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

/// A compact snapshot of the autocomplete settings the coordinator actually needs at generation
/// time. Keeping this as a value type makes change detection simple and deterministic.
struct SuggestionSettingsSnapshot: Equatable, Sendable {
    let isGloballyEnabled: Bool
    let selectedEngine: SuggestionEngineKind
    let selectedWordCountPreset: SuggestionWordCountPreset
    /// Enables incremental rendering when a backend can produce partial output.
    /// This belongs in the snapshot because streaming changes generation lifecycle, not just UI.
    let streamingAutocompleteEnabled: Bool
    let effectivePromptMode: SuggestionPromptMode
    /// Normalized user-authored guidance for the instructions-based completion style.
    /// This travels in the snapshot so generation uses the same value the Settings UI shows.
    let customAIInstructions: String?
}
