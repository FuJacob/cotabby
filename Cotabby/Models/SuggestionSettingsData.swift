import CoreGraphics
import Foundation

/// File overview:
/// The pure value representation of every durable autocomplete preference Cotabby persists.
///
/// This is the shape `SuggestionSettingsStore` loads from and saves to `UserDefaults`, and the
/// bag of values the `@MainActor` `SuggestionSettingsModel` facade fans its `@Published`
/// properties out from on launch. Keeping the plain values separate from the `ObservableObject`
/// lets the persistence and migration logic be unit-tested against an injected `UserDefaults`
/// suite without standing up SwiftUI observation. `Equatable` so tests can assert a full
/// round-trip and so the store can compare resolved-versus-stored state.
struct SuggestionSettingsData: Equatable {
    var isGloballyEnabled: Bool
    var showIndicator: Bool
    var showAcceptanceHint: Bool
    var disabledAppRules: [DisabledApplicationRule]
    /// When false (the default), ghost text is suppressed in integrated terminals (VS Code / Cursor
    /// xterm.js surfaces); a terminal's own completion/history conflicts with autocomplete and ghost
    /// text overlaps command output. Power users can opt back in.
    var suggestInIntegratedTerminals: Bool
    var customSuggestionTextColorHex: String?
    var ghostTextOpacity: Double
    /// User multiplier applied on top of the caret-approximated ghost-text size. 1.0 keeps the
    /// existing best-approximation; lower values shrink suggestions for users who find the auto-size
    /// too large. See `SuggestionSettingsStore.clampedGhostTextSizeMultiplier` for the bounds.
    var ghostTextSizeMultiplier: Double
    var selectedEngine: SuggestionEngineKind
    var selectedWordCountPreset: SuggestionWordCountPreset
    /// When true, generation uses `customWordCountLowWords...customWordCountHighWords` instead of
    /// the preset above. Stored alongside the preset (not replacing it) so toggling back from Custom
    /// restores the user's previous preset choice without having to remember it.
    var isUsingCustomWordCountRange: Bool
    var customWordCountLowWords: Int
    var customWordCountHighWords: Int
    var isClipboardContextEnabled: Bool
    /// When on (the default), prompts may state which app, window title, web domain, and field the
    /// user is typing in, so suggestions stay on-topic for the surface. Everything stays on device.
    var isSurfaceContextEnabled: Bool
    var isFastModeEnabled: Bool
    /// When on, Cotabby checks the user's current word with `NSSpellChecker` and hides the normal
    /// continuation when the word looks misspelled, so completions don't pile onto a broken word.
    var suppressCompletionsOnTypo: Bool
    /// When on (and `suppressCompletionsOnTypo` is also on), a detected typo switches into correction
    /// mode: Cotabby offers the spell-checker's fix as a green replace-the-word suggestion.
    var offerTypoCorrections: Bool
    /// ISO language codes for the bundled SymSpell dictionaries the user permits Cotabby to query.
    /// Empty means correction ranking relies exclusively on the system `NSSpellChecker`.
    var enabledSpellingDictionaryCodes: [String]
    /// When on (and typo suppression is also on), a completed misspelled word is replaced as soon as
    /// the user presses Space. This remains separate from `offerTypoCorrections`: users may keep the
    /// green preview while typing, disable it, or use both behaviors together.
    var automaticallyFixTypos: Bool
    var isPerformanceTrackingEnabled: Bool
    var isMenuBarWordCountVisible: Bool
    var mirrorPreference: MirrorPreference
    var userName: String
    var customRules: [String]
    var responseLanguages: [String]
    var extendedContext: String
    var debounceMilliseconds: Int
    var focusPollIntervalMilliseconds: Int
    var isMultiLineEnabled: Bool
    var isEmojiPickerEnabled: Bool
    var isMacroExpansionEnabled: Bool
    var preferredEmojiSkinTone: EmojiSkinTone
    var preferredEmojiGender: EmojiGender
    var autoAcceptTrailingPunctuation: Bool
    /// When on, accepting a suggestion that finishes a word also types a trailing space, so the user
    /// can keep typing the next word without pressing Space. Suppressed when the accepted text already
    /// ends in punctuation or whitespace, or in a space-less script. Defaults to off so the WYSIWYG
    /// accept behavior is unchanged unless the user opts in.
    var addSpaceAfterAccept: Bool
    /// When on, ghost text is revealed token-by-token as the model decodes, and each partial is an
    /// acceptable session the user can Tab into early. When off (the default), the suggestion appears
    /// once, fully formed, after generation finishes.
    var streamSuggestionsWhileGenerating: Bool
    /// When on (the default), a newly shown suggestion fades in over a short opacity ramp instead of
    /// snapping to full strength. Purely cosmetic and consumed only by the overlay renderer; the fade
    /// is suppressed automatically when the system "Reduce Motion" setting is on.
    var fadeInSuggestions: Bool
    /// Duration in seconds of that fade-in ramp. Read live by the overlay renderer and surfaced as a
    /// Slow-to-Fast speed slider in Settings; lower is a faster fade. See
    /// `SuggestionSettingsStore.clampedFadeInDuration` for the bounds.
    var fadeInDurationSeconds: Double
    var acceptanceKeyCode: CGKeyCode
    var acceptanceKeyModifiers: ShortcutModifierMask
    var acceptanceKeyLabel: String
    var fullAcceptanceKeyCode: CGKeyCode
    var fullAcceptanceKeyModifiers: ShortcutModifierMask
    var fullAcceptanceKeyLabel: String
    var globalToggleKeyCode: CGKeyCode
    var globalToggleKeyModifiers: ShortcutModifierMask
    var globalToggleKeyLabel: String
    var acceptanceGranularity: AcceptanceGranularity
    var isPowerBasedModelSwitchingEnabled: Bool
    var batteryEngine: SuggestionEngineKind
    var batteryModelFilename: String
    var pluggedInEngine: SuggestionEngineKind
    var pluggedInModelFilename: String
}
