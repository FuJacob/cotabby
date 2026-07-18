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
    var autoAcceptTrailingPunctuation: Bool
    var addSpaceAfterAccept: Bool
    var streamSuggestionsWhileGenerating: Bool
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
    var isMenuBarIconVisible: Bool
    var isMenuBarWordCountVisible: Bool
    var mirrorPreference: MirrorPreference
    var fadeInSuggestions: Bool
    var fadeInDurationSeconds: Double
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
struct SuggestionShortcutBindingSettings: Equatable {
    var keyCode: CGKeyCode
    var modifiers: ShortcutModifierMask
    var label: String
}

/// The three independently configurable shortcut actions.
struct SuggestionShortcutSettings: Equatable {
    var acceptance: SuggestionShortcutBindingSettings
    var fullAcceptance: SuggestionShortcutBindingSettings
    var globalToggle: SuggestionShortcutBindingSettings
}

/// Pure domain representation of every durable suggestion preference.
///
/// Persistence keys remain flat for migration compatibility, while this in-memory value is grouped
/// by the subsystem that owns each decision. The forwarding properties below preserve the previous
/// flat API for existing call sites and tests while new code can consume cohesive domain settings.
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
    var isGloballyEnabled: Bool {
        get { general.isGloballyEnabled }
        set { general.isGloballyEnabled = newValue }
    }

    var pauseState: SuggestionPauseState? {
        get { general.pauseState }
        set { general.pauseState = newValue }
    }

    var disabledAppRules: [DisabledApplicationRule] {
        get { general.disabledAppRules }
        set { general.disabledAppRules = newValue }
    }

    var suggestInIntegratedTerminals: Bool {
        get { general.suggestInIntegratedTerminals }
        set { general.suggestInIntegratedTerminals = newValue }
    }

    var isPerformanceTrackingEnabled: Bool {
        get { general.isPerformanceTrackingEnabled }
        set { general.isPerformanceTrackingEnabled = newValue }
    }

    var selectedEngine: SuggestionEngineKind {
        get { engine.selectedEngine }
        set { engine.selectedEngine = newValue }
    }

    var openAICompatibleBaseURL: String {
        get { engine.openAICompatibleBaseURL }
        set { engine.openAICompatibleBaseURL = newValue }
    }

    var openAICompatibleModelName: String {
        get { engine.openAICompatibleModelName }
        set { engine.openAICompatibleModelName = newValue }
    }

    var openAICompatibleAPIMode: OpenAICompatibleAPIMode {
        get { engine.openAICompatibleAPIMode }
        set { engine.openAICompatibleAPIMode = newValue }
    }

    var isPowerBasedModelSwitchingEnabled: Bool {
        get { engine.isPowerBasedModelSwitchingEnabled }
        set { engine.isPowerBasedModelSwitchingEnabled = newValue }
    }

    var batteryEngine: SuggestionEngineKind {
        get { engine.batteryEngine }
        set { engine.batteryEngine = newValue }
    }

    var batteryModelFilename: String {
        get { engine.batteryModelFilename }
        set { engine.batteryModelFilename = newValue }
    }

    var batteryEndpointModelName: String {
        get { engine.batteryEndpointModelName }
        set { engine.batteryEndpointModelName = newValue }
    }

    var pluggedInEngine: SuggestionEngineKind {
        get { engine.pluggedInEngine }
        set { engine.pluggedInEngine = newValue }
    }

    var pluggedInModelFilename: String {
        get { engine.pluggedInModelFilename }
        set { engine.pluggedInModelFilename = newValue }
    }

    var pluggedInEndpointModelName: String {
        get { engine.pluggedInEndpointModelName }
        set { engine.pluggedInEndpointModelName = newValue }
    }

    var selectedWordCountPreset: SuggestionWordCountPreset {
        get { completion.selectedWordCountPreset }
        set { completion.selectedWordCountPreset = newValue }
    }

    var isUsingCustomWordCountRange: Bool {
        get { completion.isUsingCustomWordCountRange }
        set { completion.isUsingCustomWordCountRange = newValue }
    }

    var customWordCountLowWords: Int {
        get { completion.customWordCountLowWords }
        set { completion.customWordCountLowWords = newValue }
    }

    var customWordCountHighWords: Int {
        get { completion.customWordCountHighWords }
        set { completion.customWordCountHighWords = newValue }
    }

    var debounceMilliseconds: Int {
        get { completion.debounceMilliseconds }
        set { completion.debounceMilliseconds = newValue }
    }

    var focusPollIntervalMilliseconds: Int {
        get { completion.focusPollIntervalMilliseconds }
        set { completion.focusPollIntervalMilliseconds = newValue }
    }

    var isMultiLineEnabled: Bool {
        get { completion.isMultiLineEnabled }
        set { completion.isMultiLineEnabled = newValue }
    }

    var autoAcceptTrailingPunctuation: Bool {
        get { completion.autoAcceptTrailingPunctuation }
        set { completion.autoAcceptTrailingPunctuation = newValue }
    }

    var addSpaceAfterAccept: Bool {
        get { completion.addSpaceAfterAccept }
        set { completion.addSpaceAfterAccept = newValue }
    }

    var streamSuggestionsWhileGenerating: Bool {
        get { completion.streamSuggestionsWhileGenerating }
        set { completion.streamSuggestionsWhileGenerating = newValue }
    }

    var acceptanceGranularity: AcceptanceGranularity {
        get { completion.acceptanceGranularity }
        set { completion.acceptanceGranularity = newValue }
    }

    var isClipboardContextEnabled: Bool {
        get { context.isClipboardContextEnabled }
        set { context.isClipboardContextEnabled = newValue }
    }

    var isSurfaceContextEnabled: Bool {
        get { context.isSurfaceContextEnabled }
        set { context.isSurfaceContextEnabled = newValue }
    }

    var isFastModeEnabled: Bool {
        get { context.isFastModeEnabled }
        set { context.isFastModeEnabled = newValue }
    }

    var userName: String {
        get { context.userName }
        set { context.userName = newValue }
    }

    var customRules: [String] {
        get { context.customRules }
        set { context.customRules = newValue }
    }

    var responseLanguages: [String] {
        get { context.responseLanguages }
        set { context.responseLanguages = newValue }
    }

    var extendedContext: String {
        get { context.extendedContext }
        set { context.extendedContext = newValue }
    }

    var suppressCompletionsOnTypo: Bool {
        get { correction.suppressCompletionsOnTypo }
        set { correction.suppressCompletionsOnTypo = newValue }
    }

    var offerTypoCorrections: Bool {
        get { correction.offerTypoCorrections }
        set { correction.offerTypoCorrections = newValue }
    }

    var enabledSpellingDictionaryCodes: [String] {
        get { correction.enabledSpellingDictionaryCodes }
        set { correction.enabledSpellingDictionaryCodes = newValue }
    }

    var automaticallyFixTypos: Bool {
        get { correction.automaticallyFixTypos }
        set { correction.automaticallyFixTypos = newValue }
    }

    var showIndicator: Bool {
        get { presentation.showIndicator }
        set { presentation.showIndicator = newValue }
    }

    var showAcceptanceHint: Bool {
        get { presentation.showAcceptanceHint }
        set { presentation.showAcceptanceHint = newValue }
    }

    var customSuggestionTextColorHex: String? {
        get { presentation.customSuggestionTextColorHex }
        set { presentation.customSuggestionTextColorHex = newValue }
    }

    var ghostTextOpacity: Double {
        get { presentation.ghostTextOpacity }
        set { presentation.ghostTextOpacity = newValue }
    }

    var ghostTextSizeMultiplier: Double {
        get { presentation.ghostTextSizeMultiplier }
        set { presentation.ghostTextSizeMultiplier = newValue }
    }

    var isMenuBarIconVisible: Bool {
        get { presentation.isMenuBarIconVisible }
        set { presentation.isMenuBarIconVisible = newValue }
    }

    var isMenuBarWordCountVisible: Bool {
        get { presentation.isMenuBarWordCountVisible }
        set { presentation.isMenuBarWordCountVisible = newValue }
    }

    var mirrorPreference: MirrorPreference {
        get { presentation.mirrorPreference }
        set { presentation.mirrorPreference = newValue }
    }

    var fadeInSuggestions: Bool {
        get { presentation.fadeInSuggestions }
        set { presentation.fadeInSuggestions = newValue }
    }

    var fadeInDurationSeconds: Double {
        get { presentation.fadeInDurationSeconds }
        set { presentation.fadeInDurationSeconds = newValue }
    }

    var isEmojiPickerEnabled: Bool {
        get { inlineFeatures.isEmojiPickerEnabled }
        set { inlineFeatures.isEmojiPickerEnabled = newValue }
    }

    var isMacroExpansionEnabled: Bool {
        get { inlineFeatures.isMacroExpansionEnabled }
        set { inlineFeatures.isMacroExpansionEnabled = newValue }
    }

    var preferredEmojiSkinTone: EmojiSkinTone {
        get { inlineFeatures.preferredEmojiSkinTone }
        set { inlineFeatures.preferredEmojiSkinTone = newValue }
    }

    var preferredEmojiGender: EmojiGender {
        get { inlineFeatures.preferredEmojiGender }
        set { inlineFeatures.preferredEmojiGender = newValue }
    }

    var acceptanceKeyCode: CGKeyCode {
        get { shortcuts.acceptance.keyCode }
        set { shortcuts.acceptance.keyCode = newValue }
    }

    var acceptanceKeyModifiers: ShortcutModifierMask {
        get { shortcuts.acceptance.modifiers }
        set { shortcuts.acceptance.modifiers = newValue }
    }

    var acceptanceKeyLabel: String {
        get { shortcuts.acceptance.label }
        set { shortcuts.acceptance.label = newValue }
    }

    var fullAcceptanceKeyCode: CGKeyCode {
        get { shortcuts.fullAcceptance.keyCode }
        set { shortcuts.fullAcceptance.keyCode = newValue }
    }

    var fullAcceptanceKeyModifiers: ShortcutModifierMask {
        get { shortcuts.fullAcceptance.modifiers }
        set { shortcuts.fullAcceptance.modifiers = newValue }
    }

    var fullAcceptanceKeyLabel: String {
        get { shortcuts.fullAcceptance.label }
        set { shortcuts.fullAcceptance.label = newValue }
    }

    var globalToggleKeyCode: CGKeyCode {
        get { shortcuts.globalToggle.keyCode }
        set { shortcuts.globalToggle.keyCode = newValue }
    }

    var globalToggleKeyModifiers: ShortcutModifierMask {
        get { shortcuts.globalToggle.modifiers }
        set { shortcuts.globalToggle.modifiers = newValue }
    }

    var globalToggleKeyLabel: String {
        get { shortcuts.globalToggle.label }
        set { shortcuts.globalToggle.label = newValue }
    }
}
