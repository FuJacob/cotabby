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
    var customSuggestionTextColorHex: String?
    var ghostTextOpacity: Double
    var selectedEngine: SuggestionEngineKind
    var selectedWordCountPreset: SuggestionWordCountPreset
    /// When true, generation uses `customWordCountLowWords...customWordCountHighWords` instead of
    /// the preset above. Stored alongside the preset (not replacing it) so toggling back from Custom
    /// restores the user's previous preset choice without having to remember it.
    var isUsingCustomWordCountRange: Bool
    var customWordCountLowWords: Int
    var customWordCountHighWords: Int
    var isClipboardContextEnabled: Bool
    var isFastModeEnabled: Bool
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
    var preferredEmojiSkinTone: EmojiSkinTone
    var preferredEmojiGender: EmojiGender
    var autoAcceptTrailingPunctuation: Bool
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
}
