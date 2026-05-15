import Foundation

/// File overview:
/// Defines the product-facing writing mode and engine choices for Tabby's suggestion pipeline.
/// This file exists because "which engine is active?" is a domain concept, not a UI-only detail.
/// The same applies to the interaction mode: runtime code needs an immutable value that says
/// whether Tabby is completing a short inline tail or preparing for a deliberate full draft.
///
/// The important architectural distinction is:
/// - autocomplete vs. compose is an interaction contract
/// - a local GGUF file is a model option inside the llama runtime
/// - Apple Intelligence vs. local llama is an engine choice above the runtime layer
enum SuggestionInteractionMode: String, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case autocomplete
    case compose

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .autocomplete:
            return "Autocomplete"
        case .compose:
            return "Compose"
        }
    }

    var explanatoryText: String {
        switch self {
        case .autocomplete:
            return "Predicts a short inline continuation near the caret."
        case .compose:
            return "Prepares a full draft for deliberate review before typing."
        }
    }
}

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

    var supportsLocalModelManagement: Bool {
        switch self {
        case .appleIntelligence:
            return false
        case .llamaOpenSource:
            return true
        }
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
    let selectedInteractionMode: SuggestionInteractionMode
    let selectedEngine: SuggestionEngineKind
    let selectedWordCountPreset: SuggestionWordCountPreset
    let isClipboardContextEnabled: Bool
    /// User-authored profile data for Tabby's single instruction-rendered completion prompt.
    /// This travels in the snapshot so generation uses the same value the Settings UI shows.
    let userName: String
    let userTags: [String]

    init(
        isGloballyEnabled: Bool,
        disabledAppBundleIdentifiers: Set<String>,
        selectedInteractionMode: SuggestionInteractionMode = .autocomplete,
        selectedEngine: SuggestionEngineKind,
        selectedWordCountPreset: SuggestionWordCountPreset,
        isClipboardContextEnabled: Bool,
        userName: String,
        userTags: [String]
    ) {
        self.isGloballyEnabled = isGloballyEnabled
        self.disabledAppBundleIdentifiers = disabledAppBundleIdentifiers
        self.selectedInteractionMode = selectedInteractionMode
        self.selectedEngine = selectedEngine
        self.selectedWordCountPreset = selectedWordCountPreset
        self.isClipboardContextEnabled = isClipboardContextEnabled
        self.userName = userName
        self.userTags = userTags
    }
}
