import CoreGraphics
import Foundation

/// Process-level enablement and host-application policy.
///
/// This value lives for as long as a loaded settings snapshot. It has no persistence behavior of
/// its own; `SuggestionSettingsStore` maps the fields to the existing UserDefaults keys.
struct SuggestionGeneralSettings: Equatable {
    var isGloballyEnabled: Bool
    var pauseState: SuggestionPauseState?
    var disabledAppRules: [DisabledApplicationRule]
    var suggestInIntegratedTerminals: Bool
    var isPerformanceTrackingEnabled: Bool
    /// Whether suggestions pause while Low Power Mode is active.
    var isLowPowerModeAutoDisableEnabled: Bool
}

/// Backend selection, endpoint configuration, and power-source routing.
struct SuggestionEngineSettings: Equatable {
    var selectedEngine: SuggestionEngineKind
    var openAICompatibleBaseURL: String
    var openAICompatibleModelName: String
    var openAICompatibleAPIMode: OpenAICompatibleAPIMode
    var isPowerBasedModelSwitchingEnabled: Bool
    var batteryEngine: SuggestionEngineKind
    var batteryModelFilename: String
    var batteryEndpointModelName: String
    var pluggedInEngine: SuggestionEngineKind
    var pluggedInModelFilename: String
    var pluggedInEndpointModelName: String
    /// When Apple Intelligence rejects a language, retry with the selected Open Source model.
    var isAppleLanguageFallbackEnabled: Bool
    /// Keep that fallback model loaded while Apple Intelligence is selected, so the first
    /// fallback suggestion does not wait for the model to load. Costs the model's memory.
    var keepsFallbackModelLoaded: Bool
}

/// Completion length, timing, streaming, and acceptance behavior.
struct SuggestionCompletionSettings: Equatable {
    var selectedWordCountPreset: SuggestionWordCountPreset
    var isUsingCustomWordCountRange: Bool
    var customWordCountLowWords: Int
    var customWordCountHighWords: Int
    var debounceMilliseconds: Int
    var focusPollIntervalMilliseconds: Int
    var isMultiLineEnabled: Bool
    /// Controls when new generation may start; a visible suggestion still follows matching typing.
    var suggestWithinWords: Bool
    /// Limits the visible preview, while the session retains following words for subsequent typing.
    var showFollowingWords: Bool
    var autoAcceptTrailingPunctuation: Bool
    var addSpaceAfterAccept: Bool
    var streamSuggestionsWhileGenerating: Bool
    /// Keeps an on-device request alive through matching typing, independently of partial display.
    var predictAheadWhileTyping: Bool
    var acceptanceGranularity: AcceptanceGranularity
}

/// Optional request context and user-authored personalization.
struct SuggestionContextSettings: Equatable {
    var isClipboardContextEnabled: Bool
    var isSurfaceContextEnabled: Bool
    var isFastModeEnabled: Bool
    var userName: String
    var customRules: [String]
    var responseLanguages: [String]
    var extendedContext: String
}

/// Deterministic spelling and typo-correction policy.
struct SuggestionCorrectionSettings: Equatable {
    var suppressCompletionsOnTypo: Bool
    var offerTypoCorrections: Bool
    var enabledSpellingDictionaryCodes: [String]
    var automaticallyFixTypos: Bool
}

/// Overlay, indicator, menu-bar, and transition presentation.
struct SuggestionPresentationSettings: Equatable {
    var showIndicator: Bool
    var showAcceptanceHint: Bool
    var customSuggestionTextColorHex: String?
    var ghostTextOpacity: Double
    var ghostTextSizeMultiplier: Double
    /// Absolute point-size clamps for ghost text, applied after the size multiplier.
    var ghostFontSizeFloor: Double
    var ghostFontSizeCeiling: Double
    var isMenuBarIconVisible: Bool
    var isMenuBarWordCountVisible: Bool
    var mirrorPreference: MirrorPreference
    var fadeInSuggestions: Bool
    var fadeInDurationSeconds: Double
    /// Draw suggestions in the bold and/or italic face of the font matched to the host. Styling only:
    /// the plain matched font still measures the host's text, so caret placement is unaffected.
    var isGhostTextBold: Bool = false
    var isGhostTextItalic: Bool = false
    /// Draws the ghost at exactly the size measured for the host's own text, so the size multiplier
    /// and the floor/ceiling above are not applied. Off by default, which keeps the user's tuning.
    var matchesHostTextSize: Bool = false
    /// UI-only developer preference. Release builds ignore it; it never enters inference snapshots.
    var showDevelopmentDebugOverlays: Bool = false
}

/// Non-model inline features that share the global input stream.
struct SuggestionInlineFeatureSettings: Equatable {
    var isEmojiPickerEnabled: Bool
    var isMacroExpansionEnabled: Bool
    var preferredEmojiSkinTone: EmojiSkinTone
    var preferredEmojiGender: EmojiGender
}

/// One complete physical key binding. Keeping key code, modifiers, and label together prevents a
/// domain value from representing a half-updated shortcut.
struct SuggestionShortcutBindingSettings: Codable, Equatable, Sendable {
    var keyCode: CGKeyCode
    var modifiers: ShortcutModifierMask
    var label: String
}

/// The independently configurable shortcut actions and app-specific overrides.
struct SuggestionShortcutSettings: Equatable {
    var acceptance: SuggestionShortcutBindingSettings
    var fullAcceptance: SuggestionShortcutBindingSettings
    var globalToggle: SuggestionShortcutBindingSettings
    var perAppOverrides: [PerAppShortcutOverride]
    /// When true, Accept Entire Suggestion is bound to a quick double press of the Accept Word key
    /// instead of a one-press key; the model's setters keep `fullAcceptance` unbound while it is on.
    /// The double tap follows each app's own Accept Word key, and applies only in apps that inherit
    /// the global Accept Entire Suggestion binding.
    var doubleTapAcceptsEntireSuggestion: Bool
    /// When true and Accept Word is plain Tab, Tab in a single-line field (an HTML `<input>`, an
    /// `NSTextField`) is left to the host, so it moves to the next field as it would without
    /// Cotabby. Accept Entire Suggestion still accepts there.
    var tabLeavesSingleLineFields: Bool = false
}

/// Pure domain representation of every durable suggestion preference.
///
/// Persistence keys remain flat for migration compatibility, while this in-memory value is grouped
/// by the subsystem that owns each decision. The read-only flat properties below let the settings
/// facade and the store's write-back name a field without knowing which domain owns it; writes go
/// through the owning domain so a field has exactly one mutable path.
struct SuggestionSettingsData: Equatable {
    var general: SuggestionGeneralSettings
    var engine: SuggestionEngineSettings
    var completion: SuggestionCompletionSettings
    var context: SuggestionContextSettings
    var correction: SuggestionCorrectionSettings
    var presentation: SuggestionPresentationSettings
    var inlineFeatures: SuggestionInlineFeatureSettings
    var shortcuts: SuggestionShortcutSettings
}

extension SuggestionSettingsData {
    var isGloballyEnabled: Bool { general.isGloballyEnabled }

    var pauseState: SuggestionPauseState? { general.pauseState }

    var disabledAppRules: [DisabledApplicationRule] { general.disabledAppRules }

    var suggestInIntegratedTerminals: Bool { general.suggestInIntegratedTerminals }

    var isPerformanceTrackingEnabled: Bool { general.isPerformanceTrackingEnabled }

    var isLowPowerModeAutoDisableEnabled: Bool { general.isLowPowerModeAutoDisableEnabled }

    var selectedEngine: SuggestionEngineKind { engine.selectedEngine }

    var openAICompatibleBaseURL: String { engine.openAICompatibleBaseURL }

    var openAICompatibleModelName: String { engine.openAICompatibleModelName }

    var openAICompatibleAPIMode: OpenAICompatibleAPIMode { engine.openAICompatibleAPIMode }

    var isPowerBasedModelSwitchingEnabled: Bool { engine.isPowerBasedModelSwitchingEnabled }

    var isAppleLanguageFallbackEnabled: Bool { engine.isAppleLanguageFallbackEnabled }

    var keepsFallbackModelLoaded: Bool { engine.keepsFallbackModelLoaded }

    var batteryEngine: SuggestionEngineKind { engine.batteryEngine }

    var batteryModelFilename: String { engine.batteryModelFilename }

    var batteryEndpointModelName: String { engine.batteryEndpointModelName }

    var pluggedInEngine: SuggestionEngineKind { engine.pluggedInEngine }

    var pluggedInModelFilename: String { engine.pluggedInModelFilename }

    var pluggedInEndpointModelName: String { engine.pluggedInEndpointModelName }

    var selectedWordCountPreset: SuggestionWordCountPreset { completion.selectedWordCountPreset }

    var isUsingCustomWordCountRange: Bool { completion.isUsingCustomWordCountRange }

    var customWordCountLowWords: Int { completion.customWordCountLowWords }

    var customWordCountHighWords: Int { completion.customWordCountHighWords }

    var debounceMilliseconds: Int { completion.debounceMilliseconds }

    var focusPollIntervalMilliseconds: Int { completion.focusPollIntervalMilliseconds }

    var isMultiLineEnabled: Bool { completion.isMultiLineEnabled }

    var suggestWithinWords: Bool { completion.suggestWithinWords }

    var showFollowingWords: Bool { completion.showFollowingWords }

    var autoAcceptTrailingPunctuation: Bool { completion.autoAcceptTrailingPunctuation }

    var addSpaceAfterAccept: Bool { completion.addSpaceAfterAccept }

    var predictAheadWhileTyping: Bool { completion.predictAheadWhileTyping }

    var streamSuggestionsWhileGenerating: Bool { completion.streamSuggestionsWhileGenerating }

    var acceptanceGranularity: AcceptanceGranularity { completion.acceptanceGranularity }

    var isClipboardContextEnabled: Bool { context.isClipboardContextEnabled }

    var isSurfaceContextEnabled: Bool { context.isSurfaceContextEnabled }

    var isFastModeEnabled: Bool { context.isFastModeEnabled }

    var userName: String { context.userName }

    var customRules: [String] { context.customRules }

    var responseLanguages: [String] { context.responseLanguages }

    var extendedContext: String { context.extendedContext }

    var suppressCompletionsOnTypo: Bool { correction.suppressCompletionsOnTypo }

    var offerTypoCorrections: Bool { correction.offerTypoCorrections }

    var enabledSpellingDictionaryCodes: [String] { correction.enabledSpellingDictionaryCodes }

    var automaticallyFixTypos: Bool { correction.automaticallyFixTypos }

    var showIndicator: Bool { presentation.showIndicator }

    var showAcceptanceHint: Bool { presentation.showAcceptanceHint }

    var customSuggestionTextColorHex: String? { presentation.customSuggestionTextColorHex }

    var ghostTextOpacity: Double { presentation.ghostTextOpacity }

    var ghostTextSizeMultiplier: Double { presentation.ghostTextSizeMultiplier }

    var ghostFontSizeFloor: Double { presentation.ghostFontSizeFloor }

    var ghostFontSizeCeiling: Double { presentation.ghostFontSizeCeiling }

    var isMenuBarIconVisible: Bool { presentation.isMenuBarIconVisible }

    var isMenuBarWordCountVisible: Bool { presentation.isMenuBarWordCountVisible }

    var mirrorPreference: MirrorPreference { presentation.mirrorPreference }

    var fadeInSuggestions: Bool { presentation.fadeInSuggestions }

    var isGhostTextBold: Bool { presentation.isGhostTextBold }

    var isGhostTextItalic: Bool { presentation.isGhostTextItalic }

    var fadeInDurationSeconds: Double { presentation.fadeInDurationSeconds }

    var matchesHostTextSize: Bool { presentation.matchesHostTextSize }

    var isEmojiPickerEnabled: Bool { inlineFeatures.isEmojiPickerEnabled }

    var isMacroExpansionEnabled: Bool { inlineFeatures.isMacroExpansionEnabled }

    var preferredEmojiSkinTone: EmojiSkinTone { inlineFeatures.preferredEmojiSkinTone }

    var preferredEmojiGender: EmojiGender { inlineFeatures.preferredEmojiGender }

    var acceptanceKeyCode: CGKeyCode { shortcuts.acceptance.keyCode }

    var acceptanceKeyModifiers: ShortcutModifierMask { shortcuts.acceptance.modifiers }

    var acceptanceKeyLabel: String { shortcuts.acceptance.label }

    var fullAcceptanceKeyCode: CGKeyCode { shortcuts.fullAcceptance.keyCode }

    var fullAcceptanceKeyModifiers: ShortcutModifierMask { shortcuts.fullAcceptance.modifiers }

    var fullAcceptanceKeyLabel: String { shortcuts.fullAcceptance.label }

    var globalToggleKeyCode: CGKeyCode { shortcuts.globalToggle.keyCode }

    var globalToggleKeyModifiers: ShortcutModifierMask { shortcuts.globalToggle.modifiers }

    var globalToggleKeyLabel: String { shortcuts.globalToggle.label }

    var perAppShortcutOverrides: [PerAppShortcutOverride] { shortcuts.perAppOverrides }

    var doubleTapAcceptsEntireSuggestion: Bool { shortcuts.doubleTapAcceptsEntireSuggestion }

    var tabLeavesSingleLineFields: Bool { shortcuts.tabLeavesSingleLineFields }
}
