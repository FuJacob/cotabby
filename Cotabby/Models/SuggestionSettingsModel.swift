import ApplicationServices
import Combine
import Foundation

/// Identifies one of the three user-configurable keyboard shortcuts so the recorder can ask which
/// other action (if any) already owns a proposed key combination before committing it.
enum ShortcutAction: CaseIterable {
    case acceptWord
    case acceptEntireSuggestion
    case toggleTabby

    var displayName: String {
        switch self {
        case .acceptWord: return "Accept Word"
        case .acceptEntireSuggestion: return "Accept Entire Suggestion"
        case .toggleTabby: return "Toggle Tabby"
        }
    }
}

/// File overview:
/// Owns the durable autocomplete preferences that are shared across the app:
/// engine selection, completion length, indicator appearance, and profile
/// personalization.
///
/// This type is the right owner for these values because they are product settings, not
/// `SuggestionCoordinator` session state. The coordinator should react to settings changes, not
/// persist them itself.
@MainActor
final class SuggestionSettingsModel: ObservableObject {
    @Published private(set) var isGloballyEnabled: Bool
    @Published private(set) var showIndicator: Bool
    /// Whether the keycap hint (the small pill that teaches the accept key) is drawn after ghost text.
    @Published private(set) var showAcceptanceHint: Bool
    @Published private(set) var disabledAppRules: [DisabledApplicationRule]
    @Published private(set) var customSuggestionTextColorHex: String?
    @Published private(set) var ghostTextOpacity: Double
    @Published private(set) var selectedEngine: SuggestionEngineKind
    @Published private(set) var selectedWordCountPreset: SuggestionWordCountPreset
    @Published private(set) var isClipboardContextEnabled: Bool
    @Published private(set) var isFastModeEnabled: Bool
    /// Whether the Performance pane is recording per-request latency. Defaults to false so the
    /// default user never pays any extra storage or write cost — recording only kicks in once the
    /// user opts in from Settings.
    @Published private(set) var isPerformanceTrackingEnabled: Bool
    /// Whether the accepted-word counter is drawn next to the menu bar icon. Off hides the badge
    /// entirely; the count itself keeps accruing so toggling it back on restores the running total.
    @Published private(set) var isMenuBarWordCountVisible: Bool
    /// How suggestions are presented (inline ghost text vs popup card vs auto).
    @Published private(set) var mirrorPreference: MirrorPreference
    @Published private(set) var userName: String
    @Published private(set) var customRules: [String]
    @Published private(set) var responseLanguages: [String]
    /// Free-form user-authored context (glossary, jargon, style notes) injected into every
    /// completion request. Empty string when unset. Trimmed and length-capped on write so an
    /// accidental paste of a huge document can't blow out the model's context window.
    @Published private(set) var extendedContext: String
    @Published private(set) var debounceMilliseconds: Int
    @Published private(set) var focusPollIntervalMilliseconds: Int
    @Published private(set) var isMultiLineEnabled: Bool
    /// Whether the inline `:emoji:` picker is active. Read live by `EmojiPickerController` at event
    /// time, so toggling it takes effect on the next keystroke without restarting capture.
    @Published private(set) var isEmojiPickerEnabled: Bool
    /// Emoji-customization preferences, read live by the picker's variant resolver at match time.
    @Published private(set) var preferredEmojiSkinTone: EmojiSkinTone
    @Published private(set) var preferredEmojiGender: EmojiGender
    @Published private(set) var autoAcceptTrailingPunctuation: Bool
    @Published private(set) var acceptanceKeyCode: CGKeyCode
    @Published private(set) var acceptanceKeyModifiers: ShortcutModifierMask
    @Published private(set) var acceptanceKeyLabel: String
    @Published private(set) var fullAcceptanceKeyCode: CGKeyCode
    @Published private(set) var fullAcceptanceKeyModifiers: ShortcutModifierMask
    @Published private(set) var fullAcceptanceKeyLabel: String
    /// User-configurable hotkey that flips `isGloballyEnabled`. Defaults to unbound so the user has
    /// to opt in; without a binding the listener tap for this hotkey is never installed.
    @Published private(set) var globalToggleKeyCode: CGKeyCode
    @Published private(set) var globalToggleKeyModifiers: ShortcutModifierMask
    @Published private(set) var globalToggleKeyLabel: String
    @Published private(set) var acceptanceGranularity: AcceptanceGranularity
    private let userDefaults: UserDefaults

    private static let isGloballyEnabledDefaultsKey = "cotabbyGloballyEnabled"
    private static let disabledAppRulesDefaultsKey = "cotabbyDisabledAppRules"
    private static let showCaretIndicatorDefaultsKey = "cotabbyShowCaretIndicator"
    private static let selectedIndicatorModeDefaultsKey = "cotabbySelectedIndicatorMode"
    private static let showAcceptanceHintDefaultsKey = "cotabbyShowAcceptanceHint"
    private static let customSuggestionTextColorHexDefaultsKey = "cotabbyCustomSuggestionTextColorHex"
    private static let ghostTextOpacityDefaultsKey = "cotabbyGhostTextOpacity"
    private static let selectedEngineDefaultsKey = "cotabbySelectedEngine"
    private static let selectedWordCountPresetDefaultsKey = "cotabbySelectedWordCountPreset"
    /// Pre-#475 raw value for the shortest length tier. Kept here only so the read path can
    /// rewrite it to `.fourToSeven` on launch; never re-emitted to UserDefaults.
    private static let legacyShortPresetRawValue = "3-7"
    private static let clipboardContextEnabledDefaultsKey = "cotabbyClipboardContextEnabled"
    private static let fastModeEnabledDefaultsKey = "cotabbyFastModeEnabled"
    private static let performanceTrackingEnabledDefaultsKey = "cotabbyPerformanceTrackingEnabled"
    private static let menuBarWordCountVisibleDefaultsKey = "cotabbyMenuBarWordCountVisible"
    private static let mirrorPreferenceDefaultsKey = "cotabbyMirrorPreference"
    private static let userNameDefaultsKey = "cotabbyUserName"
    private static let customRulesDefaultsKey = "cotabbyCustomRules"
    private static let extendedContextDefaultsKey = "cotabbyExtendedContext"
    private static let responseLanguagesDefaultsKey = "cotabbyResponseLanguages"
    /// Legacy single-select key, read once to migrate the previous value into `responseLanguages`.
    private static let legacyResponseLanguageDefaultsKey = "cotabbyResponseLanguage"
    private static let debounceMillisecondsDefaultsKey = "cotabbyDebounceMilliseconds"
    private static let focusPollIntervalMillisecondsDefaultsKey = "cotabbyFocusPollIntervalMilliseconds"
    private static let multiLineEnabledDefaultsKey = "cotabbyMultiLineEnabled"
    private static let emojiPickerEnabledDefaultsKey = "cotabbyEmojiPickerEnabled"
    private static let preferredEmojiSkinToneDefaultsKey = "cotabbyPreferredEmojiSkinTone"
    private static let preferredEmojiGenderDefaultsKey = "cotabbyPreferredEmojiGender"
    private static let autoAcceptTrailingPunctuationDefaultsKey = "cotabbyAutoAcceptTrailingPunctuation"
    private static let acceptanceKeyCodeDefaultsKey = "cotabbyAcceptanceKeyCode"
    private static let acceptanceKeyModifiersDefaultsKey = "cotabbyAcceptanceKeyModifiers"
    private static let acceptanceKeyLabelDefaultsKey = "cotabbyAcceptanceKeyLabel"
    private static let fullAcceptanceKeyCodeDefaultsKey = "cotabbyFullAcceptanceKeyCode"
    private static let fullAcceptanceKeyModifiersDefaultsKey = "cotabbyFullAcceptanceKeyModifiers"
    private static let fullAcceptanceKeyLabelDefaultsKey = "cotabbyFullAcceptanceKeyLabel"
    private static let globalToggleKeyCodeDefaultsKey = "cotabbyGlobalToggleKeyCode"
    private static let globalToggleKeyModifiersDefaultsKey = "cotabbyGlobalToggleKeyModifiers"
    private static let globalToggleKeyLabelDefaultsKey = "cotabbyGlobalToggleKeyLabel"
    private static let acceptanceGranularityDefaultsKey = "cotabbyAcceptanceGranularity"

    static let defaultAcceptanceKeyCode: CGKeyCode = 48
    static let defaultAcceptanceKeyLabel = "Tab"
    /// A key code that will never match a real keyboard event, used to represent "no keybind".
    static let disabledKeyCode: CGKeyCode = CGKeyCode(UInt16.max)
    static let disabledKeyLabel = "None"
    /// `kVK_ANSI_Grave` — the `~`/`` ` `` key in the keyboard's top-left corner. Out-of-box default
    /// because Tab partial-acceptance is awkward when the user wants the whole continuation, and
    /// `` ` `` is rarely used in prose so the binding doesn't fight normal typing.
    static let defaultFullAcceptanceKeyCode: CGKeyCode = 50
    static let defaultFullAcceptanceKeyLabel = "`"

    /// Floor kept above zero so ghost text can be faded but never made fully invisible (which would
    /// look like the suggestion engine is broken). 100% is the out-of-box default.
    static let minimumGhostTextOpacity: Double = 0.3
    static let maximumGhostTextOpacity: Double = 1.0
    static let defaultGhostTextOpacity: Double = 1.0
    static let ghostTextOpacityStep: Double = 0.1

    /// Hard upper bound on the persisted Extended Context blob, in characters. Sized so the user
    /// can paste a meaningful glossary or style guide without crowding the model's shared context:
    /// roughly ~1000 tokens of English, which still leaves headroom for instructions, prefix text,
    /// clipboard, and visual context inside Apple's 4096-token window. Larger pastes are truncated
    /// at write time so the cost is bounded on every subsequent request.
    static let maximumExtendedContextCharacters: Int = 4_000

    init(
        configuration: SuggestionConfiguration,
        userDefaults: UserDefaults = .standard
    ) {
        self.userDefaults = userDefaults

        let resolvedGloballyEnabled = userDefaults.object(forKey: Self.isGloballyEnabledDefaultsKey) as? Bool ?? true
        let resolvedDisabledAppRules = Self.loadDisabledAppRules(from: userDefaults)
        let resolvedShowIndicator: Bool = if let modeString = userDefaults.string(
            forKey: Self.selectedIndicatorModeDefaultsKey
        ) {
            modeString != ActivationIndicatorMode.hidden.rawValue
        } else {
            userDefaults.object(forKey: Self.showCaretIndicatorDefaultsKey) as? Bool ?? true
        }
        let resolvedShowAcceptanceHint = userDefaults.object(forKey: Self.showAcceptanceHintDefaultsKey) as? Bool ?? true
        let resolvedCustomSuggestionTextColorHex = Self.normalizedHexString(
            userDefaults.string(forKey: Self.customSuggestionTextColorHexDefaultsKey)
        )
        let resolvedGhostTextOpacity: Double = if userDefaults.object(forKey: Self.ghostTextOpacityDefaultsKey) == nil {
            Self.defaultGhostTextOpacity
        } else {
            Self.clampedGhostTextOpacity(userDefaults.double(forKey: Self.ghostTextOpacityDefaultsKey))
        }
        let resolvedEngine = userDefaults
            .string(forKey: Self.selectedEngineDefaultsKey)
            .flatMap(SuggestionEngineKind.init(rawValue:))
            ?? .llamaOpenSource
        let resolvedWordCountPreset: SuggestionWordCountPreset = {
            let storedRaw = userDefaults.string(forKey: Self.selectedWordCountPresetDefaultsKey)
            // Migrate the retired "3-7" raw value to its replacement "4-7" so users who picked
            // the short preset don't silently jump to the default after #475 split the short
            // tier into 2-4 and 4-7.
            if storedRaw == Self.legacyShortPresetRawValue {
                return .fourToSeven
            }
            return storedRaw.flatMap(SuggestionWordCountPreset.init(rawValue:))
                ?? configuration.defaultWordCountPreset
        }()
        let resolvedClipboardContextEnabled =
            userDefaults.object(forKey: Self.clipboardContextEnabledDefaultsKey) as? Bool ?? false
        // Defaults to false so the visual-context pipeline keeps running for existing users; opting
        // into fast mode turns it off.
        let resolvedFastModeEnabled =
            userDefaults.object(forKey: Self.fastModeEnabledDefaultsKey) as? Bool ?? false
        // Defaults to false so the metrics ring buffer stays empty until the user explicitly opts
        // in from the Performance pane.
        let resolvedPerformanceTrackingEnabled =
            userDefaults.object(forKey: Self.performanceTrackingEnabledDefaultsKey) as? Bool ?? false
        // Default to visible so existing installs keep the running-word-count badge they're used
        // to seeing. The toggle lets users who find the badge noisy hide it from the menu bar.
        let resolvedMenuBarWordCountVisible =
            userDefaults.object(forKey: Self.menuBarWordCountVisibleDefaultsKey) as? Bool ?? true
        // Default `.auto` keeps existing users on the byte-for-byte original inline rendering for
        // hosts that report exact/derived caret geometry; only `.estimated` hosts see the new popup
        // card. Power users can pin one mode from Settings or the menu bar.
        let resolvedMirrorPreference = userDefaults
            .string(forKey: Self.mirrorPreferenceDefaultsKey)
            .flatMap(MirrorPreference.init(rawValue:))
            ?? .auto
        let resolvedUserName: String = if userDefaults.object(forKey: Self.userNameDefaultsKey) == nil {
            configuration.defaultUserName ?? ""
        } else {
            userDefaults.string(forKey: Self.userNameDefaultsKey) ?? ""
        }

        // Absent key means a fresh install: seed the baseline rules (currently empty — rules are
        // opt-in). A present (even empty) value means the user has touched their rules — including
        // clearing them — so we honor it verbatim. Note: the unconditional persist below writes the
        // seeded value back, so the absent/present distinction only matters on the very first launch;
        // if `defaultRules` is ever made non-empty, seed before that first write or existing users
        // (already holding `[]`) won't receive the new defaults.
        let resolvedCustomRules: [String] = if userDefaults.object(forKey: Self.customRulesDefaultsKey) == nil {
            CustomRulesCatalog.defaultRules
        } else {
            CustomRulesCatalog.normalize(userDefaults.stringArray(forKey: Self.customRulesDefaultsKey) ?? [])
        }

        let resolvedExtendedContext = Self.normalizedExtendedContext(
            userDefaults.string(forKey: Self.extendedContextDefaultsKey) ?? ""
        )

        // Prefer the multi-language value once the user has touched it (key present, even if empty).
        // Otherwise migrate the previous single-select choice exactly once; a fresh install gets the
        // empty default.
        let resolvedResponseLanguages: [String] = if userDefaults.object(forKey: Self.responseLanguagesDefaultsKey) != nil {
            LanguageCatalog.normalize(userDefaults.stringArray(forKey: Self.responseLanguagesDefaultsKey) ?? [])
        } else if let legacyCode = userDefaults.string(forKey: Self.legacyResponseLanguageDefaultsKey) {
            LanguageCatalog.migratedLanguages(fromLegacyCode: legacyCode)
        } else {
            LanguageCatalog.defaultLanguages
        }

        let resolvedDebounceMilliseconds: Int = {
            let raw = userDefaults.object(forKey: Self.debounceMillisecondsDefaultsKey) as? Int
                ?? configuration.debounceMilliseconds
            // Existing installs may have the old 50ms first-launch default persisted. Cap at the
            // shipped default so the latency improvement reaches them — the stepper is hidden from
            // the UI today, so any persisted value is a previous default rather than a user choice.
            let capped = min(raw, configuration.debounceMilliseconds)
            return max(10, min(500, capped))
        }()
        let resolvedFocusPollIntervalMilliseconds: Int = {
            let raw = userDefaults.object(forKey: Self.focusPollIntervalMillisecondsDefaultsKey) as? Int
                ?? configuration.focusPollIntervalMilliseconds
            // Cap persisted values at the shipped default so a default lowering reaches existing
            // installs (anyone on the previous 80ms default gets the 50ms speedup on next launch).
            // The stepper is hidden from the UI today, so any persisted value is a previous default
            // rather than a user-chosen override.
            let capped = min(raw, configuration.focusPollIntervalMilliseconds)
            return max(10, min(500, capped))
        }()

        let resolvedMultiLineEnabled = userDefaults.object(forKey: Self.multiLineEnabledDefaultsKey) as? Bool ?? false
        let resolvedEmojiPickerEnabled = userDefaults.object(forKey: Self.emojiPickerEnabledDefaultsKey) as? Bool ?? true
        let resolvedPreferredEmojiSkinTone = userDefaults.string(forKey: Self.preferredEmojiSkinToneDefaultsKey)
            .flatMap(EmojiSkinTone.init(rawValue:)) ?? .neutral
        let resolvedPreferredEmojiGender = userDefaults.string(forKey: Self.preferredEmojiGenderDefaultsKey)
            .flatMap(EmojiGender.init(rawValue:)) ?? .neutral
        let resolvedAutoAcceptTrailingPunctuation =
            userDefaults.object(forKey: Self.autoAcceptTrailingPunctuationDefaultsKey) as? Bool ?? true

        let resolvedAcceptanceKeyCode = CGKeyCode(
            userDefaults.object(forKey: Self.acceptanceKeyCodeDefaultsKey) as? Int
                ?? Int(Self.defaultAcceptanceKeyCode)
        )
        // Absence means a pre-modifier-support install: default to no modifiers so the user's
        // existing bare-key binding keeps working exactly as it did before this feature.
        let resolvedAcceptanceKeyModifiers = ShortcutModifierMask(
            rawValue: UInt32(userDefaults.object(forKey: Self.acceptanceKeyModifiersDefaultsKey) as? Int ?? 0)
        )
        let resolvedAcceptanceKeyLabel = userDefaults.string(forKey: Self.acceptanceKeyLabelDefaultsKey)
            ?? Self.defaultAcceptanceKeyLabel

        let resolvedFullAcceptanceKeyCode = CGKeyCode(
            userDefaults.object(forKey: Self.fullAcceptanceKeyCodeDefaultsKey) as? Int
                ?? Int(Self.defaultFullAcceptanceKeyCode)
        )
        let resolvedFullAcceptanceKeyModifiers = ShortcutModifierMask(
            rawValue: UInt32(userDefaults.object(forKey: Self.fullAcceptanceKeyModifiersDefaultsKey) as? Int ?? 0)
        )
        let resolvedFullAcceptanceKeyLabel = userDefaults.string(forKey: Self.fullAcceptanceKeyLabelDefaultsKey)
            ?? Self.defaultFullAcceptanceKeyLabel

        // Default is unbound. An absent UserDefaults entry must NOT fall back to a real key code —
        // the hotkey is opt-in, and silently binding something would surprise existing users.
        let resolvedGlobalToggleKeyCode = CGKeyCode(
            userDefaults.object(forKey: Self.globalToggleKeyCodeDefaultsKey) as? Int
                ?? Int(Self.disabledKeyCode)
        )
        let resolvedGlobalToggleKeyModifiers = ShortcutModifierMask(
            rawValue: UInt32(userDefaults.object(forKey: Self.globalToggleKeyModifiersDefaultsKey) as? Int ?? 0)
        )
        let resolvedGlobalToggleKeyLabel = userDefaults.string(forKey: Self.globalToggleKeyLabelDefaultsKey)
            ?? Self.disabledKeyLabel
        // Default `.word` preserves the pre-feature behavior for existing installs that have no
        // value persisted yet. Invalid persisted values fall back to `.word` rather than crashing
        // so a hand-edited UserDefault can't strand the user.
        let resolvedAcceptanceGranularity = userDefaults
            .string(forKey: Self.acceptanceGranularityDefaultsKey)
            .flatMap(AcceptanceGranularity.init(rawValue:))
            ?? .word

        isGloballyEnabled = resolvedGloballyEnabled
        disabledAppRules = resolvedDisabledAppRules
        showIndicator = resolvedShowIndicator
        showAcceptanceHint = resolvedShowAcceptanceHint
        customSuggestionTextColorHex = resolvedCustomSuggestionTextColorHex
        ghostTextOpacity = resolvedGhostTextOpacity
        selectedEngine = resolvedEngine
        selectedWordCountPreset = resolvedWordCountPreset
        isClipboardContextEnabled = resolvedClipboardContextEnabled
        isFastModeEnabled = resolvedFastModeEnabled
        isPerformanceTrackingEnabled = resolvedPerformanceTrackingEnabled
        isMenuBarWordCountVisible = resolvedMenuBarWordCountVisible
        mirrorPreference = resolvedMirrorPreference
        userName = resolvedUserName
        customRules = resolvedCustomRules
        extendedContext = resolvedExtendedContext
        responseLanguages = resolvedResponseLanguages
        debounceMilliseconds = resolvedDebounceMilliseconds
        focusPollIntervalMilliseconds = resolvedFocusPollIntervalMilliseconds
        isMultiLineEnabled = resolvedMultiLineEnabled
        isEmojiPickerEnabled = resolvedEmojiPickerEnabled
        preferredEmojiSkinTone = resolvedPreferredEmojiSkinTone
        preferredEmojiGender = resolvedPreferredEmojiGender
        autoAcceptTrailingPunctuation = resolvedAutoAcceptTrailingPunctuation
        acceptanceKeyCode = resolvedAcceptanceKeyCode
        acceptanceKeyModifiers = resolvedAcceptanceKeyModifiers
        acceptanceKeyLabel = resolvedAcceptanceKeyLabel
        fullAcceptanceKeyCode = resolvedFullAcceptanceKeyCode
        fullAcceptanceKeyModifiers = resolvedFullAcceptanceKeyModifiers
        fullAcceptanceKeyLabel = resolvedFullAcceptanceKeyLabel
        globalToggleKeyCode = resolvedGlobalToggleKeyCode
        globalToggleKeyModifiers = resolvedGlobalToggleKeyModifiers
        globalToggleKeyLabel = resolvedGlobalToggleKeyLabel
        acceptanceGranularity = resolvedAcceptanceGranularity

        userDefaults.set(resolvedGloballyEnabled, forKey: Self.isGloballyEnabledDefaultsKey)
        persistDisabledAppRules(resolvedDisabledAppRules)
        persistShowIndicator(resolvedShowIndicator)
        userDefaults.set(resolvedShowAcceptanceHint, forKey: Self.showAcceptanceHintDefaultsKey)
        persistCustomSuggestionTextColorHex(resolvedCustomSuggestionTextColorHex)
        userDefaults.set(resolvedGhostTextOpacity, forKey: Self.ghostTextOpacityDefaultsKey)
        persistSelectedEngine(resolvedEngine)
        persistSelectedWordCountPreset(resolvedWordCountPreset)
        persistClipboardContextEnabled(resolvedClipboardContextEnabled)
        persistFastModeEnabled(resolvedFastModeEnabled)
        persistPerformanceTrackingEnabled(resolvedPerformanceTrackingEnabled)
        persistMenuBarWordCountVisible(resolvedMenuBarWordCountVisible)
        persistMirrorPreference(resolvedMirrorPreference)
        persistUserName(resolvedUserName)
        persistCustomRules(resolvedCustomRules)
        persistExtendedContext(resolvedExtendedContext)
        persistResponseLanguages(resolvedResponseLanguages)
        userDefaults.set(resolvedDebounceMilliseconds, forKey: Self.debounceMillisecondsDefaultsKey)
        userDefaults.set(resolvedFocusPollIntervalMilliseconds, forKey: Self.focusPollIntervalMillisecondsDefaultsKey)
        userDefaults.set(resolvedMultiLineEnabled, forKey: Self.multiLineEnabledDefaultsKey)
        userDefaults.set(resolvedEmojiPickerEnabled, forKey: Self.emojiPickerEnabledDefaultsKey)
        userDefaults.set(resolvedPreferredEmojiSkinTone.rawValue, forKey: Self.preferredEmojiSkinToneDefaultsKey)
        userDefaults.set(resolvedPreferredEmojiGender.rawValue, forKey: Self.preferredEmojiGenderDefaultsKey)
        userDefaults.set(resolvedAutoAcceptTrailingPunctuation, forKey: Self.autoAcceptTrailingPunctuationDefaultsKey)
        userDefaults.set(Int(resolvedAcceptanceKeyCode), forKey: Self.acceptanceKeyCodeDefaultsKey)
        userDefaults.set(Int(resolvedAcceptanceKeyModifiers.rawValue), forKey: Self.acceptanceKeyModifiersDefaultsKey)
        userDefaults.set(resolvedAcceptanceKeyLabel, forKey: Self.acceptanceKeyLabelDefaultsKey)
        userDefaults.set(Int(resolvedFullAcceptanceKeyCode), forKey: Self.fullAcceptanceKeyCodeDefaultsKey)
        userDefaults.set(
            Int(resolvedFullAcceptanceKeyModifiers.rawValue),
            forKey: Self.fullAcceptanceKeyModifiersDefaultsKey
        )
        userDefaults.set(resolvedFullAcceptanceKeyLabel, forKey: Self.fullAcceptanceKeyLabelDefaultsKey)
        userDefaults.set(Int(resolvedGlobalToggleKeyCode), forKey: Self.globalToggleKeyCodeDefaultsKey)
        userDefaults.set(
            Int(resolvedGlobalToggleKeyModifiers.rawValue),
            forKey: Self.globalToggleKeyModifiersDefaultsKey
        )
        userDefaults.set(resolvedGlobalToggleKeyLabel, forKey: Self.globalToggleKeyLabelDefaultsKey)
        userDefaults.set(resolvedAcceptanceGranularity.rawValue, forKey: Self.acceptanceGranularityDefaultsKey)

        // The custom indicator icon feature was removed; scrub any previously-persisted PNG so
        // users who picked one in an older build get the default cat icon back automatically.
        userDefaults.removeObject(forKey: "cotabbyCustomIndicatorImageData")
    }

    /// Legacy compatibility shim. Reads through to `showIndicator`.
    var showCaretIndicator: Bool {
        showIndicator
    }

    var snapshot: SuggestionSettingsSnapshot {
        SuggestionSettingsSnapshot(
            isGloballyEnabled: isGloballyEnabled,
            disabledAppBundleIdentifiers: Set(disabledAppRules.map(\.bundleIdentifier)),
            selectedEngine: selectedEngine,
            selectedWordCountPreset: selectedWordCountPreset,
            isClipboardContextEnabled: isClipboardContextEnabled,
            userName: userName,
            customRules: customRules,
            extendedContext: extendedContext,
            responseLanguages: responseLanguages,
            debounceMilliseconds: debounceMilliseconds,
            focusPollIntervalMilliseconds: focusPollIntervalMilliseconds,
            isMultiLineEnabled: isMultiLineEnabled,
            autoAcceptTrailingPunctuation: autoAcceptTrailingPunctuation,
            isFastModeEnabled: isFastModeEnabled,
            mirrorPreference: mirrorPreference,
            acceptanceGranularity: acceptanceGranularity
        )
    }

    func selectEngine(_ engine: SuggestionEngineKind) {
        guard selectedEngine != engine else {
            return
        }

        selectedEngine = engine
        persistSelectedEngine(engine)
    }

    func selectWordCountPreset(_ preset: SuggestionWordCountPreset) {
        guard selectedWordCountPreset != preset else {
            return
        }

        selectedWordCountPreset = preset
        persistSelectedWordCountPreset(preset)
    }

    func setClipboardContextEnabled(_ enabled: Bool) {
        guard isClipboardContextEnabled != enabled else {
            return
        }

        isClipboardContextEnabled = enabled
        persistClipboardContextEnabled(enabled)
    }

    func setFastModeEnabled(_ enabled: Bool) {
        guard isFastModeEnabled != enabled else {
            return
        }

        isFastModeEnabled = enabled
        persistFastModeEnabled(enabled)
    }

    func setPerformanceTrackingEnabled(_ enabled: Bool) {
        guard isPerformanceTrackingEnabled != enabled else {
            return
        }

        isPerformanceTrackingEnabled = enabled
        persistPerformanceTrackingEnabled(enabled)
    }

    func setMenuBarWordCountVisible(_ visible: Bool) {
        guard isMenuBarWordCountVisible != visible else {
            return
        }

        isMenuBarWordCountVisible = visible
        persistMenuBarWordCountVisible(visible)
    }

    func setMirrorPreference(_ preference: MirrorPreference) {
        guard mirrorPreference != preference else {
            return
        }

        mirrorPreference = preference
        persistMirrorPreference(preference)
    }

    func setMultiLineEnabled(_ enabled: Bool) {
        guard isMultiLineEnabled != enabled else {
            return
        }
        isMultiLineEnabled = enabled
        userDefaults.set(enabled, forKey: Self.multiLineEnabledDefaultsKey)
    }

    func setEmojiPickerEnabled(_ enabled: Bool) {
        guard isEmojiPickerEnabled != enabled else {
            return
        }
        isEmojiPickerEnabled = enabled
        userDefaults.set(enabled, forKey: Self.emojiPickerEnabledDefaultsKey)
    }

    func setPreferredEmojiSkinTone(_ tone: EmojiSkinTone) {
        guard preferredEmojiSkinTone != tone else { return }
        preferredEmojiSkinTone = tone
        userDefaults.set(tone.rawValue, forKey: Self.preferredEmojiSkinToneDefaultsKey)
    }

    func setPreferredEmojiGender(_ gender: EmojiGender) {
        guard preferredEmojiGender != gender else { return }
        preferredEmojiGender = gender
        userDefaults.set(gender.rawValue, forKey: Self.preferredEmojiGenderDefaultsKey)
    }

    /// Live snapshot the emoji picker's variant resolver reads at match time.
    var emojiVariantPreferences: EmojiVariantPreferences {
        EmojiVariantPreferences(
            skinTone: preferredEmojiSkinTone,
            gender: preferredEmojiGender
        )
    }

    func setAutoAcceptTrailingPunctuation(_ enabled: Bool) {
        guard autoAcceptTrailingPunctuation != enabled else {
            return
        }
        autoAcceptTrailingPunctuation = enabled
        userDefaults.set(enabled, forKey: Self.autoAcceptTrailingPunctuationDefaultsKey)
    }

    func setAcceptanceGranularity(_ granularity: AcceptanceGranularity) {
        guard acceptanceGranularity != granularity else {
            return
        }
        acceptanceGranularity = granularity
        userDefaults.set(granularity.rawValue, forKey: Self.acceptanceGranularityDefaultsKey)
    }

    func setGloballyEnabled(_ enabled: Bool) {
        guard isGloballyEnabled != enabled else {
            return
        }

        isGloballyEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isGloballyEnabledDefaultsKey)
    }

    func setApplicationDisabled(
        bundleIdentifier: String?,
        displayName: String,
        disabled: Bool
    ) {
        guard let normalizedBundleIdentifier = Self.normalizedBundleIdentifier(bundleIdentifier) else {
            return
        }

        if disabled {
            disableApplication(
                bundleIdentifier: normalizedBundleIdentifier,
                displayName: displayName
            )
        } else {
            removeDisabledApplication(bundleIdentifier: normalizedBundleIdentifier)
        }
    }

    func disableApplication(
        bundleIdentifier: String,
        displayName: String
    ) {
        guard let normalizedBundleIdentifier = Self.normalizedBundleIdentifier(bundleIdentifier) else {
            return
        }

        let normalizedDisplayName = Self.normalizedDisplayName(
            displayName,
            fallbackBundleIdentifier: normalizedBundleIdentifier
        )
        let rule = DisabledApplicationRule(
            bundleIdentifier: normalizedBundleIdentifier,
            displayName: normalizedDisplayName
        )
        var updatedRulesByBundleIdentifier = Dictionary(
            uniqueKeysWithValues: disabledAppRules.map { ($0.bundleIdentifier, $0) }
        )
        updatedRulesByBundleIdentifier[normalizedBundleIdentifier] = rule
        let updatedRules = Self.sortedDisabledAppRules(Array(updatedRulesByBundleIdentifier.values))

        guard disabledAppRules != updatedRules else {
            return
        }

        disabledAppRules = updatedRules
        persistDisabledAppRules(updatedRules)
    }

    func removeDisabledApplication(bundleIdentifier: String?) {
        guard let normalizedBundleIdentifier = Self.normalizedBundleIdentifier(bundleIdentifier)
        else {
            return
        }

        let updatedRules = disabledAppRules.filter {
            $0.bundleIdentifier != normalizedBundleIdentifier
        }

        guard disabledAppRules != updatedRules else {
            return
        }

        disabledAppRules = updatedRules
        persistDisabledAppRules(updatedRules)
    }

    func isApplicationDisabled(bundleIdentifier: String?) -> Bool {
        guard let normalizedBundleIdentifier = Self.normalizedBundleIdentifier(bundleIdentifier)
        else {
            return false
        }

        return disabledAppRules.contains {
            $0.bundleIdentifier == normalizedBundleIdentifier
        }
    }

    func setShowIndicator(_ show: Bool) {
        guard showIndicator != show else {
            return
        }

        showIndicator = show
        persistShowIndicator(show)
    }

    func setShowAcceptanceHint(_ show: Bool) {
        guard showAcceptanceHint != show else {
            return
        }

        showAcceptanceHint = show
        userDefaults.set(show, forKey: Self.showAcceptanceHintDefaultsKey)
    }

    /// The label the ghost-text keycap should display, or `nil` when no hint should be drawn —
    /// either the user turned it off or no key is currently bound to accept a suggestion. Prefers
    /// the word-accept key (the historical "tab" pill) and falls back to the full-accept key so the
    /// hint still teaches a working gesture after the word-accept key has been cleared.
    var acceptanceHintLabel: String? {
        guard showAcceptanceHint else {
            return nil
        }

        if acceptanceKeyCode != Self.disabledKeyCode {
            return acceptanceKeyLabel
        }
        if fullAcceptanceKeyCode != Self.disabledKeyCode {
            return fullAcceptanceKeyLabel
        }
        return nil
    }

    /// The emoji picker commits with the word-accept shortcut specifically. This is separate from
    /// `acceptanceHintLabel` because hiding ghost-text hints should not hide the picker instruction.
    var emojiPickerAcceptKeyLabel: String? {
        acceptanceKeyCode == Self.disabledKeyCode ? nil : acceptanceKeyLabel
    }

    func setCustomSuggestionTextColorHex(_ hex: String?) {
        let normalizedHex = Self.normalizedHexString(hex)
        guard customSuggestionTextColorHex != normalizedHex else {
            return
        }

        customSuggestionTextColorHex = normalizedHex
        persistCustomSuggestionTextColorHex(normalizedHex)
    }

    func setGhostTextOpacity(_ opacity: Double) {
        let clamped = Self.clampedGhostTextOpacity(opacity)
        guard ghostTextOpacity != clamped else {
            return
        }

        ghostTextOpacity = clamped
        userDefaults.set(clamped, forKey: Self.ghostTextOpacityDefaultsKey)
    }

    func setUserName(_ name: String) {
        guard userName != name else {
            return
        }

        userName = name
        persistUserName(name)
    }

    /// All rule mutations funnel through here so storage stays normalized (trimmed, deduped, capped).
    func setRules(_ rules: [String]) {
        let normalized = CustomRulesCatalog.normalize(rules)
        guard customRules != normalized else {
            return
        }

        customRules = normalized
        persistCustomRules(normalized)
    }

    func addRule(_ rule: String) {
        setRules(customRules + [rule])
    }

    func removeRule(_ rule: String) {
        setRules(customRules.filter { $0 != rule })
    }

    /// Restores the baseline rule set, which is currently empty (rules are opt-in). See
    /// `CustomRulesCatalog.defaultRules`. Named for the UI affordance ("Clear"): if that baseline is
    /// ever made non-empty, revisit this name and the editor's button label together.
    func clearRules() {
        setRules(CustomRulesCatalog.defaultRules)
    }

    /// All extended-context mutations funnel through here so storage stays bounded — leading and
    /// trailing whitespace is trimmed and the body is hard-capped at
    /// `maximumExtendedContextCharacters` so a runaway paste cannot blow out the model's context
    /// window on every subsequent request.
    func setExtendedContext(_ context: String) {
        let normalized = Self.normalizedExtendedContext(context)
        guard extendedContext != normalized else {
            return
        }

        extendedContext = normalized
        persistExtendedContext(normalized)
    }

    /// All language mutations funnel through here so storage stays normalized (trimmed, deduped,
    /// capped), mirroring `setRules`.
    func setLanguages(_ languages: [String]) {
        let normalized = LanguageCatalog.normalize(languages)
        guard responseLanguages != normalized else {
            return
        }

        responseLanguages = normalized
        persistResponseLanguages(normalized)
    }

    func addLanguage(_ language: String) {
        setLanguages(responseLanguages + [language])
    }

    func removeLanguage(_ language: String) {
        setLanguages(responseLanguages.filter { $0 != language })
    }

    /// Restores the baseline (empty) language set. Named for the editor's "Clear" affordance.
    func clearLanguages() {
        setLanguages(LanguageCatalog.defaultLanguages)
    }

    func setAcceptanceKey(keyCode: CGKeyCode, modifiers: ShortcutModifierMask, label: String) {
        let normalizedModifiers = keyCode == Self.disabledKeyCode ? [] : modifiers
        guard acceptanceKeyCode != keyCode
            || acceptanceKeyModifiers != normalizedModifiers
            || acceptanceKeyLabel != label
        else {
            return
        }

        // Two bindings on the same `(keyCode, modifiers)` would both fire on the same press,
        // so clear the other side to keep classification unambiguous. We only treat it as a
        // conflict when both the key and the modifier set match — `Tab` and `⇧Tab` are now
        // distinct bindings and may coexist.
        if keyCode != Self.disabledKeyCode,
           keyCode == fullAcceptanceKeyCode,
           normalizedModifiers == fullAcceptanceKeyModifiers {
            clearFullAcceptanceKey()
        }

        acceptanceKeyCode = keyCode
        acceptanceKeyModifiers = normalizedModifiers
        acceptanceKeyLabel = label
        userDefaults.set(Int(keyCode), forKey: Self.acceptanceKeyCodeDefaultsKey)
        userDefaults.set(Int(normalizedModifiers.rawValue), forKey: Self.acceptanceKeyModifiersDefaultsKey)
        userDefaults.set(label, forKey: Self.acceptanceKeyLabelDefaultsKey)
    }

    func clearAcceptanceKey() {
        setAcceptanceKey(keyCode: Self.disabledKeyCode, modifiers: [], label: Self.disabledKeyLabel)
    }

    func setFullAcceptanceKey(keyCode: CGKeyCode, modifiers: ShortcutModifierMask, label: String) {
        let normalizedModifiers = keyCode == Self.disabledKeyCode ? [] : modifiers
        guard fullAcceptanceKeyCode != keyCode
            || fullAcceptanceKeyModifiers != normalizedModifiers
            || fullAcceptanceKeyLabel != label
        else {
            return
        }

        if keyCode != Self.disabledKeyCode,
           keyCode == acceptanceKeyCode,
           normalizedModifiers == acceptanceKeyModifiers {
            clearAcceptanceKey()
        }

        fullAcceptanceKeyCode = keyCode
        fullAcceptanceKeyModifiers = normalizedModifiers
        fullAcceptanceKeyLabel = label
        userDefaults.set(Int(keyCode), forKey: Self.fullAcceptanceKeyCodeDefaultsKey)
        userDefaults.set(Int(normalizedModifiers.rawValue), forKey: Self.fullAcceptanceKeyModifiersDefaultsKey)
        userDefaults.set(label, forKey: Self.fullAcceptanceKeyLabelDefaultsKey)
    }

    func clearFullAcceptanceKey() {
        setFullAcceptanceKey(keyCode: Self.disabledKeyCode, modifiers: [], label: Self.disabledKeyLabel)
    }

    /// Persists a new global-toggle hotkey. Modifiers are normalized to empty when the key code is
    /// `disabledKeyCode` so the listener tap can rely on `(disabled, [])` meaning "do not install
    /// the tap at all" without inspecting the modifier set separately.
    func setGlobalToggleKey(keyCode: CGKeyCode, modifiers: ShortcutModifierMask, label: String) {
        let normalizedModifiers = keyCode == Self.disabledKeyCode ? [] : modifiers
        guard globalToggleKeyCode != keyCode
            || globalToggleKeyModifiers != normalizedModifiers
            || globalToggleKeyLabel != label
        else {
            return
        }

        globalToggleKeyCode = keyCode
        globalToggleKeyModifiers = normalizedModifiers
        globalToggleKeyLabel = label
        userDefaults.set(Int(keyCode), forKey: Self.globalToggleKeyCodeDefaultsKey)
        userDefaults.set(Int(normalizedModifiers.rawValue), forKey: Self.globalToggleKeyModifiersDefaultsKey)
        userDefaults.set(label, forKey: Self.globalToggleKeyLabelDefaultsKey)
    }

    func clearGlobalToggleKey() {
        setGlobalToggleKey(keyCode: Self.disabledKeyCode, modifiers: [], label: Self.disabledKeyLabel)
    }

    // All stored state is thread-safe to release (Combine subjects, UserDefaults). The
    // nonisolated deinit prevents Swift from scheduling the teardown through the
    // back-deployment main-actor executor shim, which has a StopLookupScope bug on macOS 26.
    nonisolated deinit {}

    /// Convenience used by the hotkey callback. Wrapping the flip here keeps the InputMonitor
    /// closure trivial and gives the menu bar / tests a single entry point.
    func toggleGloballyEnabled() {
        setGloballyEnabled(!isGloballyEnabled)
    }

    /// Returns the user-facing name of the shortcut action already bound to `(keyCode, modifiers)`,
    /// excluding `action` itself, or `nil` when the combo is free.
    ///
    /// This is the single source of truth the recorder consults before committing a new binding.
    /// Without it the global-toggle hotkey can silently collide with an accept key: the toggle tap
    /// is head-inserted but the accept tap (installed later while a suggestion is visible) sits ahead
    /// of it and consumes the shared key first, so the toggle never fires. Blocking the duplicate up
    /// front keeps every binding unambiguous. The disabled sentinel never conflicts — several actions
    /// may be left unbound at once.
    func conflictingShortcutName(
        keyCode: CGKeyCode,
        modifiers: ShortcutModifierMask,
        excluding action: ShortcutAction
    ) -> String? {
        guard keyCode != Self.disabledKeyCode else { return nil }

        for other in ShortcutAction.allCases where other != action {
            let binding = shortcutBinding(for: other)
            if binding.keyCode == keyCode, binding.modifiers == modifiers {
                return other.displayName
            }
        }
        return nil
    }

    private func shortcutBinding(for action: ShortcutAction) -> (keyCode: CGKeyCode, modifiers: ShortcutModifierMask) {
        switch action {
        case .acceptWord:
            return (acceptanceKeyCode, acceptanceKeyModifiers)
        case .acceptEntireSuggestion:
            return (fullAcceptanceKeyCode, fullAcceptanceKeyModifiers)
        case .toggleTabby:
            return (globalToggleKeyCode, globalToggleKeyModifiers)
        }
    }

    private func persistSelectedEngine(_ engine: SuggestionEngineKind) {
        userDefaults.set(engine.rawValue, forKey: Self.selectedEngineDefaultsKey)
    }

    private func persistSelectedWordCountPreset(_ preset: SuggestionWordCountPreset) {
        userDefaults.set(preset.rawValue, forKey: Self.selectedWordCountPresetDefaultsKey)
    }

    private func persistClipboardContextEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: Self.clipboardContextEnabledDefaultsKey)
    }

    private func persistFastModeEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: Self.fastModeEnabledDefaultsKey)
    }

    private func persistPerformanceTrackingEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: Self.performanceTrackingEnabledDefaultsKey)
    }

    private func persistMenuBarWordCountVisible(_ visible: Bool) {
        userDefaults.set(visible, forKey: Self.menuBarWordCountVisibleDefaultsKey)
    }

    private func persistMirrorPreference(_ preference: MirrorPreference) {
        userDefaults.set(preference.rawValue, forKey: Self.mirrorPreferenceDefaultsKey)
    }

    private func persistShowIndicator(_ show: Bool) {
        let mode: ActivationIndicatorMode = show ? .fieldEdgeIcon : .hidden
        userDefaults.set(mode.rawValue, forKey: Self.selectedIndicatorModeDefaultsKey)
        userDefaults.set(show, forKey: Self.showCaretIndicatorDefaultsKey)
    }

    private func persistCustomSuggestionTextColorHex(_ hex: String?) {
        if let hex {
            userDefaults.set(hex, forKey: Self.customSuggestionTextColorHexDefaultsKey)
        } else {
            userDefaults.removeObject(forKey: Self.customSuggestionTextColorHexDefaultsKey)
        }
    }

    private static func loadDisabledAppRules(from userDefaults: UserDefaults) -> [DisabledApplicationRule] {
        guard let data = userDefaults.data(forKey: Self.disabledAppRulesDefaultsKey),
              let decodedRules = try? JSONDecoder().decode([DisabledApplicationRule].self, from: data)
        else {
            return []
        }

        return sanitizedDisabledAppRules(decodedRules)
    }

    private static func sanitizedDisabledAppRules(
        _ rules: [DisabledApplicationRule]
    ) -> [DisabledApplicationRule] {
        var rulesByBundleIdentifier: [String: DisabledApplicationRule] = [:]

        for rule in rules {
            guard let normalizedBundleIdentifier = normalizedBundleIdentifier(rule.bundleIdentifier)
            else {
                continue
            }

            rulesByBundleIdentifier[normalizedBundleIdentifier] = DisabledApplicationRule(
                bundleIdentifier: normalizedBundleIdentifier,
                displayName: normalizedDisplayName(
                    rule.displayName,
                    fallbackBundleIdentifier: normalizedBundleIdentifier
                )
            )
        }

        return sortedDisabledAppRules(Array(rulesByBundleIdentifier.values))
    }

    private static func sortedDisabledAppRules(
        _ rules: [DisabledApplicationRule]
    ) -> [DisabledApplicationRule] {
        rules.sorted {
            if $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedSame {
                return $0.bundleIdentifier < $1.bundleIdentifier
            }

            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private static func normalizedBundleIdentifier(_ bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier else {
            return nil
        }

        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedDisplayName(
        _ displayName: String,
        fallbackBundleIdentifier: String
    ) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackBundleIdentifier : trimmed
    }

    private static func clampedGhostTextOpacity(_ value: Double) -> Double {
        guard value.isFinite else {
            return defaultGhostTextOpacity
        }

        return min(maximumGhostTextOpacity, max(minimumGhostTextOpacity, value))
    }

    private static func normalizedHexString(_ hex: String?) -> String? {
        guard let hex else {
            return nil
        }

        let trimmed = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
        let validCharacters = CharacterSet(charactersIn: "0123456789ABCDEF")
        guard trimmed.count == 6,
              trimmed.unicodeScalars.allSatisfy(validCharacters.contains(_:))
        else {
            return nil
        }

        return trimmed
    }

    private func persistUserName(_ name: String) {
        userDefaults.set(name, forKey: Self.userNameDefaultsKey)
    }

    private func persistCustomRules(_ rules: [String]) {
        userDefaults.set(rules, forKey: Self.customRulesDefaultsKey)
    }

    private func persistExtendedContext(_ context: String) {
        if context.isEmpty {
            userDefaults.removeObject(forKey: Self.extendedContextDefaultsKey)
        } else {
            userDefaults.set(context, forKey: Self.extendedContextDefaultsKey)
        }
    }

    /// Length-cap the persisted body at `maximumExtendedContextCharacters` so an accidental paste
    /// of a huge document can't blow out the model's context window on every subsequent request.
    ///
    /// Whitespace is intentionally NOT trimmed here. The TextEditor binding writes back through
    /// `setExtendedContext` on every keystroke, so any trim — including a trailing-space trim —
    /// would strip whitespace the user is mid-way through typing, making it impossible to type a
    /// space at the end of a word. Whitespace-only content is collapsed back to "no value" in
    /// `SuggestionRequestFactory` instead, where the cost is paid once per request rather than once
    /// per keystroke.
    private static func normalizedExtendedContext(_ context: String) -> String {
        guard context.count > maximumExtendedContextCharacters else {
            return context
        }
        return String(context.prefix(maximumExtendedContextCharacters))
    }

    private func persistResponseLanguages(_ languages: [String]) {
        userDefaults.set(languages, forKey: Self.responseLanguagesDefaultsKey)
    }

    private func persistDisabledAppRules(_ rules: [DisabledApplicationRule]) {
        guard !rules.isEmpty else {
            userDefaults.removeObject(forKey: Self.disabledAppRulesDefaultsKey)
            return
        }

        if let data = try? JSONEncoder().encode(rules) {
            userDefaults.set(data, forKey: Self.disabledAppRulesDefaultsKey)
        }
    }
}

extension SuggestionSettingsModel: SuggestionSettingsProviding {
    var snapshotPublisher: AnyPublisher<SuggestionSettingsSnapshot, Never> {
        // The publisher count creeps up as we add settings, but Combine caps each operator at 4
        // upstreams. Group related settings into nested combiners so the shape stays readable.
        // `presentationToggles` carries the visual-pipeline knobs (clipboard, fast mode, mirror
        // preference); they share the property of "affects how/when suggestions are shown".
        //
        // The outer CombineLatest4 is at the cap, so `$acceptanceGranularity` is layered above it
        // via a second CombineLatest to avoid restructuring the existing groupings.
        let primary = Publishers.CombineLatest4(
            Publishers.CombineLatest4(
                $isGloballyEnabled,
                $disabledAppRules,
                $selectedEngine,
                $selectedWordCountPreset
            ),
            Publishers.CombineLatest3($isClipboardContextEnabled, $isFastModeEnabled, $mirrorPreference),
            Publishers.CombineLatest3($userName, $customRules, $responseLanguages),
            Publishers.CombineLatest4(
                $debounceMilliseconds,
                $focusPollIntervalMilliseconds,
                $isMultiLineEnabled,
                $autoAcceptTrailingPunctuation
            )
        )
        // The outer CombineLatest stack is already at Combine's per-operator cap, so each new
        // top-level setting gets layered above via another `CombineLatest`. `extendedContext` joins
        // alongside `acceptanceGranularity` here for the same reason.
        return Publishers.CombineLatest3(primary, $acceptanceGranularity, $extendedContext)
            .map { primaryTuple, granularity, extendedContext in
                let (combinedSettings, presentationToggles, profile, timing) = primaryTuple
                let (globallyEnabled, disabledAppRules, engine, wordCountPreset) = combinedSettings
                let (clipboardContextEnabled, fastModeEnabled, mirrorPreference) = presentationToggles
                let (userName, customRules, responseLanguages) = profile
                let (debounce, focusPoll, multiLine, autoAcceptPunctuation) = timing
                return SuggestionSettingsSnapshot(
                    isGloballyEnabled: globallyEnabled,
                    disabledAppBundleIdentifiers: Set(disabledAppRules.map(\.bundleIdentifier)),
                    selectedEngine: engine,
                    selectedWordCountPreset: wordCountPreset,
                    isClipboardContextEnabled: clipboardContextEnabled,
                    userName: userName,
                    customRules: customRules,
                    extendedContext: extendedContext,
                    responseLanguages: responseLanguages,
                    debounceMilliseconds: debounce,
                    focusPollIntervalMilliseconds: focusPoll,
                    isMultiLineEnabled: multiLine,
                    autoAcceptTrailingPunctuation: autoAcceptPunctuation,
                    isFastModeEnabled: fastModeEnabled,
                    mirrorPreference: mirrorPreference,
                    acceptanceGranularity: granularity
                )
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}
