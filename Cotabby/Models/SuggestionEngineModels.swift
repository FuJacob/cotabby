import Foundation

/// File overview:
/// Defines the product-facing engine choices for Cotabby's autocomplete pipeline.
/// This file exists because "which engine is active?" is a domain concept, not a UI-only detail.
///
/// The important architectural distinction is:
/// - a local GGUF file is a model option inside the llama runtime
/// - Apple Intelligence vs. local llama vs. MLX is an engine choice above the runtime layer
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
    let selectedEngine: SuggestionEngineKind
    let selectedWordCountPreset: SuggestionWordCountPreset
    let isClipboardContextEnabled: Bool
    /// User-authored profile data for Cotabby's single instruction-rendered completion prompt.
    /// This travels in the snapshot so generation uses the same value the Settings UI shows.
    let userName: String
    let debounceMilliseconds: Int
    let focusPollIntervalMilliseconds: Int
    let isMultiLineEnabled: Bool
}
