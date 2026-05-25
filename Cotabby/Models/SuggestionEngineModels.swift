import Foundation

/// File overview:
/// Defines the product-facing writing mode and engine choices for Cotabby's suggestion pipeline.
/// This file exists because "which engine is active?" is a domain concept, not a UI-only detail.
/// The same applies to the interaction mode: runtime code needs an immutable value that says
/// whether Cotabby is completing a short inline tail or preparing for a deliberate full draft.
///
/// The important architectural distinction is:
/// - autocomplete vs. compose is an interaction contract
/// - a local GGUF/MLX file is a model option inside its respective runtime
/// - Apple Intelligence vs. local llama vs. MLX is an engine choice above the runtime layer
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
    case mlxSwift

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .appleIntelligence:
            return "Apple Intelligence [BETA]"
        case .llamaOpenSource:
            return "Open Source"
        case .mlxSwift:
            return "MLX (Apple Silicon)"
        }
    }

    var supportsLocalModelManagement: Bool {
        switch self {
        case .appleIntelligence:
            return false
        case .llamaOpenSource, .mlxSwift:
            return true
        }
    }

    var modelFormat: ModelFormat? {
        switch self {
        case .appleIntelligence:
            return nil
        case .llamaOpenSource:
            return .gguf
        case .mlxSwift:
            return .mlx
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
    /// User-authored profile data for Cotabby's single instruction-rendered completion prompt.
    /// This travels in the snapshot so generation uses the same value the Settings UI shows.
    let userName: String
    /// Optional user-authored tags used by Compose Mode prompts.
    /// Currently always empty; the model does not yet surface a tag editor, but Compose's prompt
    /// renderer reads this field so future tagging UI can land without re-plumbing.
    let userTags: [String]
    let debounceMilliseconds: Int
    let focusPollIntervalMilliseconds: Int

    init(
        isGloballyEnabled: Bool,
        disabledAppBundleIdentifiers: Set<String>,
        selectedInteractionMode: SuggestionInteractionMode = .autocomplete,
        selectedEngine: SuggestionEngineKind,
        selectedWordCountPreset: SuggestionWordCountPreset,
        isClipboardContextEnabled: Bool,
        userName: String,
        userTags: [String] = [],
        debounceMilliseconds: Int,
        focusPollIntervalMilliseconds: Int
    ) {
        self.isGloballyEnabled = isGloballyEnabled
        self.disabledAppBundleIdentifiers = disabledAppBundleIdentifiers
        self.selectedInteractionMode = selectedInteractionMode
        self.selectedEngine = selectedEngine
        self.selectedWordCountPreset = selectedWordCountPreset
        self.isClipboardContextEnabled = isClipboardContextEnabled
        self.userName = userName
        self.userTags = userTags
        self.debounceMilliseconds = debounceMilliseconds
        self.focusPollIntervalMilliseconds = focusPollIntervalMilliseconds
    }
}
