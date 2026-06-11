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

/// A per-power-source suggestion configuration: which engine to use and, for the local llama engine,
/// which downloaded model file. Apple Intelligence carries no model file because the OS owns the
/// model. Used by the power-based switching feature to pick an engine + model per power state, and as
/// the single selection tag for the per-state pickers in Settings.
enum PowerProfile: Equatable, Hashable {
    case appleIntelligence
    case llama(filename: String)

    /// The engine this profile selects. Settings persists engine + filename separately, so this is
    /// the bridge from those two stored fields to a single picker selection (and back).
    var engine: SuggestionEngineKind {
        switch self {
        case .appleIntelligence:
            return .appleIntelligence
        case .llama:
            return .llamaOpenSource
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

/// How much of a buffered suggestion the primary accept key takes per press. The dedicated
/// full-accept key always takes the entire remaining tail regardless of this setting, so this
/// enum intentionally does not include a "full" case — that would duplicate the dedicated key.
enum AcceptanceGranularity: String, CaseIterable, Codable, Sendable {
    /// One word (with the existing trailing-punctuation policy applied per chunk).
    case word
    /// Words accumulated until a sentence terminator (`.`, `!`, `?`, `\n`) or the tail runs out.
    case phrase
}

/// A compact snapshot of the autocomplete settings the coordinator actually needs at generation
/// time. Keeping this as a value type makes change detection simple and deterministic.
struct SuggestionSettingsSnapshot: Equatable, Sendable {
    let isGloballyEnabled: Bool
    let disabledAppBundleIdentifiers: Set<String>
    let selectedEngine: SuggestionEngineKind
    let selectedWordCountPreset: SuggestionWordCountPreset
    /// When true, the generation pipeline uses `customWordCountRange` for the length budget and
    /// prompt cue; otherwise it falls back to `selectedWordCountPreset.range`.
    let isUsingCustomWordCountRange: Bool
    let customWordCountRange: SuggestionWordRange
    let isClipboardContextEnabled: Bool
    /// User-authored profile data for Cotabby's base-model completion prompt.
    /// This travels in the snapshot so generation uses the same value the Settings UI shows.
    let userName: String
    /// User-authored style rules, carried in the snapshot so generation uses the same value the
    /// Settings UI shows.
    let customRules: [String]
    /// Free-form glossary / terminology / style notes pasted by the user in the Extended Context
    /// settings pane. Already trimmed and length-capped by `SuggestionSettingsModel`; empty string
    /// when the user has not set it. Travels in the snapshot so generation reflects the live value.
    let extendedContext: String
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
    /// How much of the buffered suggestion the primary accept key takes per press. Read once per
    /// accept call so a mid-press setting change can't strand a partially-handled press.
    let acceptanceGranularity: AcceptanceGranularity
    /// When true, Cotabby checks the current word with `NSSpellChecker` and hides the normal
    /// continuation when it looks misspelled. Travels in the snapshot so the prediction gate reads
    /// the live value without subscribing to the settings model directly.
    let suppressCompletionsOnTypo: Bool
    /// When true (and `suppressCompletionsOnTypo` is also true), a detected typo is offered a native
    /// spell-checker correction instead of being silently suppressed. No effect when suppression is off.
    let offerTypoCorrections: Bool
    /// Normalized ISO codes for the bundled SymSpell dictionaries eligible for correction ranking.
    /// Language routing chooses at most one per typo; an empty array uses only `NSSpellChecker`.
    let enabledSpellingDictionaryCodes: [String]
    /// When true (and typo suppression is on), a correction is applied automatically after the user
    /// commits the misspelled word with Space. The word boundary prevents pauses in unfinished words
    /// from triggering destructive edits.
    let automaticallyFixTypos: Bool

    /// Single chokepoint that picks between the preset's range and the user's custom range.
    /// Every downstream consumer (token-budget math, prompt-instruction text, UI labels in the
    /// playground) should read this rather than poking the preset directly so the custom-range
    /// toggle stays load-bearing.
    var effectiveWordRange: SuggestionWordRange {
        isUsingCustomWordCountRange ? customWordCountRange : selectedWordCountPreset.range
    }
}
