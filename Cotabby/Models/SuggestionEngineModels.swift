import Foundation

/// File overview:
/// Defines the product-facing engine choices for Cotabby's autocomplete pipeline.
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
    let selectedEngine: SuggestionEngineKind
    let selectedWordCountPreset: SuggestionWordCountPreset
    let isClipboardContextEnabled: Bool
    /// User-authored profile data for Cotabby's single instruction-rendered completion prompt.
    /// This travels in the snapshot so generation uses the same value the Settings UI shows.
    let userName: String
    /// User-authored style rules, carried in the snapshot so generation uses the same value the
    /// Settings UI shows.
    let customRules: [String]
    /// The languages the user has declared they write in. Used to build a soft prompt hint; an empty
    /// set emits no directive (the renderers then just match the surrounding text). Never forces a
    /// language, so a code-switcher's other languages are preserved.
    let responseLanguages: [String]
    let debounceMilliseconds: Int
    let focusPollIntervalMilliseconds: Int
    let isMultiLineEnabled: Bool
    /// When true (the default), accepting a word also takes punctuation attached to it. When false,
    /// trailing punctuation is left as its own acceptance part so a single Tab takes the word alone.
    let autoAcceptTrailingPunctuation: Bool
    /// When true, the screenshot/OCR visual-context pipeline is skipped entirely for lower-latency
    /// suggestions. Defaults to false. Only affects visual context — predictions still run.
    let isFastModeEnabled: Bool
    /// User preference for how suggestions are presented (inline ghost text vs popup card vs auto
    /// based on caret geometry quality). Travels in the snapshot so consumers can react to changes
    /// without subscribing to the settings model directly.
    let mirrorPreference: MirrorPreference
}
