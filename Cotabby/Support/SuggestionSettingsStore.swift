import CoreGraphics
import Foundation

/// File overview:
/// Loads, migrates, and persists `SuggestionSettingsData` against `UserDefaults`. This is the only
/// type that knows the on-disk keys, the first-launch defaults, and the legacy-value migrations.
///
/// Pulling this out of the `@MainActor` `SuggestionSettingsModel` facade keeps the
/// correctness-sensitive migration logic (which protects an existing user's settings across an app
/// update) testable against an injected `UserDefaults` suite without SwiftUI observation. The facade
/// owns one of these, calls `load(configuration:)` once on launch, and routes each setter through the
/// matching `save…` method. The pure default constants and value normalizers live here too so the
/// facade and the store share one source of truth; the facade re-exports the public ones for the UI.
struct SuggestionSettingsStore {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    // MARK: - Public default constants (re-exported by SuggestionSettingsModel for the Settings UI)

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

    /// Multiplier the overlay applies on top of the caret-approximated ghost-text size. 1.0 is the
    /// out-of-box default (the unchanged best-approximation). The band is symmetric around 1.0 with
    /// real shrink room because "suggestions look too big" is the common complaint, and is kept
    /// narrow on both ends so neither extreme renders ghost text illegibly small or comically large.
    static let minimumGhostTextSizeMultiplier: Double = 0.7
    static let maximumGhostTextSizeMultiplier: Double = 1.3
    static let defaultGhostTextSizeMultiplier: Double = 1.0
    static let ghostTextSizeMultiplierStep: Double = 0.1

    /// Hard upper bound on the persisted Extended Context blob, in characters. Sized to match what the
    /// engines actually consume rather than what they can store: the OSS base path renders this as a
    /// budgeted "notes" section (`BaseCompletionPromptRenderer`, `maxChars` 1300) inside a 2400-char
    /// prompt, so a larger cap would just be clipped on-device instead of used. ~1200 chars (~300
    /// tokens) is a meaningful glossary or style guide that still leaves room for the prefix and other
    /// context, and stays well inside Apple's 4096-token window on the Foundation Models path. Keep this
    /// at or below the notes section's `maxChars` minus its label so the full blob survives on the OSS
    /// path. Larger pastes are truncated at write time so the cost is bounded on every request.
    static let maximumExtendedContextCharacters: Int = 1_200

    // MARK: - UserDefaults keys

    private static let isGloballyEnabledDefaultsKey = "cotabbyGloballyEnabled"
    private static let disabledAppRulesDefaultsKey = "cotabbyDisabledAppRules"
    private static let showCaretIndicatorDefaultsKey = "cotabbyShowCaretIndicator"
    private static let selectedIndicatorModeDefaultsKey = "cotabbySelectedIndicatorMode"
    private static let showAcceptanceHintDefaultsKey = "cotabbyShowAcceptanceHint"
    private static let customSuggestionTextColorHexDefaultsKey = "cotabbyCustomSuggestionTextColorHex"
    private static let ghostTextOpacityDefaultsKey = "cotabbyGhostTextOpacity"
    private static let ghostTextSizeMultiplierDefaultsKey = "cotabbyGhostTextSizeMultiplier"
    private static let selectedEngineDefaultsKey = "cotabbySelectedEngine"
    private static let selectedWordCountPresetDefaultsKey = "cotabbySelectedWordCountPreset"
    private static let usingCustomWordCountRangeDefaultsKey = "cotabbyUsingCustomWordCountRange"
    private static let customWordCountLowWordsDefaultsKey = "cotabbyCustomWordCountLowWords"
    private static let customWordCountHighWordsDefaultsKey = "cotabbyCustomWordCountHighWords"
    /// First-launch defaults for the custom-range fields when the user has never opened the editor.
    /// Sized around the everyday preset so flipping Custom on is immediately usable rather than
    /// landing on an arbitrary 1-1 range.
    static let defaultCustomWordCountLowWords: Int = 5
    static let defaultCustomWordCountHighWords: Int = 15
    /// Pre-#475 raw value for the shortest length tier. Kept here only so the read path can
    /// rewrite it to `.fourToSeven` on launch; never re-emitted to UserDefaults.
    private static let legacyShortPresetRawValue = "3-7"
    private static let clipboardContextEnabledDefaultsKey = "cotabbyClipboardContextEnabled"
    private static let fastModeEnabledDefaultsKey = "cotabbyFastModeEnabled"
    private static let suppressCompletionsOnTypoDefaultsKey = "cotabbySuppressCompletionsOnTypo"
    private static let offerTypoCorrectionsDefaultsKey = "cotabbyOfferTypoCorrections"
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
    private static let macroExpansionEnabledDefaultsKey = "cotabbyMacroExpansionEnabled"
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

    private static let powerModelSwitchingEnabledDefaultsKey = "cotabbyPowerBasedModelSwitchingEnabled"
    private static let batteryEngineDefaultsKey = "cotabbyBatteryEngine"
    private static let batteryModelFilenameDefaultsKey = "cotabbyBatteryModelFilename"
    private static let pluggedInEngineDefaultsKey = "cotabbyPluggedInEngine"
    private static let pluggedInModelFilenameDefaultsKey = "cotabbyPluggedInModelFilename"

    // MARK: - Load

    /// Resolves every preference from `UserDefaults`, applying first-launch defaults and the legacy
    /// migrations, then writes the resolved values back so the migrations are sticky. The unconditional
    /// write-back is load-bearing: it re-persists rewritten legacy values and default lowerings so they
    /// reach existing installs on the very next launch. Do not reorder or prune the resolution branches
    /// without a matching migration test; each one protects an existing user's settings.
    func load(configuration: SuggestionConfiguration) -> SuggestionSettingsData {
        let resolvedGloballyEnabled = userDefaults.object(forKey: Self.isGloballyEnabledDefaultsKey) as? Bool ?? true
        let resolvedDisabledAppRules = loadDisabledAppRules()
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
        let resolvedGhostTextSizeMultiplier: Double =
            if userDefaults.object(forKey: Self.ghostTextSizeMultiplierDefaultsKey) == nil {
                Self.defaultGhostTextSizeMultiplier
            } else {
                Self.clampedGhostTextSizeMultiplier(userDefaults.double(forKey: Self.ghostTextSizeMultiplierDefaultsKey))
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
        let resolvedUsingCustomWordCountRange =
            userDefaults.object(forKey: Self.usingCustomWordCountRangeDefaultsKey) as? Bool ?? false
        let resolvedCustomRange: SuggestionWordRange = SuggestionWordRange.clamped(
            low: userDefaults.object(forKey: Self.customWordCountLowWordsDefaultsKey) as? Int
                ?? Self.defaultCustomWordCountLowWords,
            high: userDefaults.object(forKey: Self.customWordCountHighWordsDefaultsKey) as? Int
                ?? Self.defaultCustomWordCountHighWords
        )
        let resolvedClipboardContextEnabled =
            userDefaults.object(forKey: Self.clipboardContextEnabledDefaultsKey) as? Bool ?? false
        // Defaults to false so the visual-context pipeline keeps running for existing users; opting
        // into fast mode turns it off.
        let resolvedFastModeEnabled =
            userDefaults.object(forKey: Self.fastModeEnabledDefaultsKey) as? Bool ?? false
        // Default both typo toggles to true: hiding a completion on a misspelled current word and
        // offering a fix are the right out-of-box behavior. Existing users without a stored value
        // get them on; the second is only effective when the first is on.
        let resolvedSuppressCompletionsOnTypo =
            userDefaults.object(forKey: Self.suppressCompletionsOnTypoDefaultsKey) as? Bool ?? true
        let resolvedOfferTypoCorrections =
            userDefaults.object(forKey: Self.offerTypoCorrectionsDefaultsKey) as? Bool ?? true
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
        let resolvedMacroExpansionEnabled = userDefaults.object(forKey: Self.macroExpansionEnabledDefaultsKey) as? Bool ?? true
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

        let resolvedPowerBasedModelSwitchingEnabled =
            userDefaults.object(forKey: Self.powerModelSwitchingEnabledDefaultsKey) as? Bool ?? false
        let resolvedBatteryEngine = userDefaults.string(forKey: Self.batteryEngineDefaultsKey)
            .flatMap(SuggestionEngineKind.init(rawValue:)) ?? .llamaOpenSource
        let resolvedBatteryModelFilename = userDefaults.string(forKey: Self.batteryModelFilenameDefaultsKey) ?? ""
        let resolvedPluggedInEngine = userDefaults.string(forKey: Self.pluggedInEngineDefaultsKey)
            .flatMap(SuggestionEngineKind.init(rawValue:)) ?? .llamaOpenSource
        let resolvedPluggedInModelFilename = userDefaults.string(forKey: Self.pluggedInModelFilenameDefaultsKey) ?? ""

        let data = SuggestionSettingsData(
            isGloballyEnabled: resolvedGloballyEnabled,
            showIndicator: resolvedShowIndicator,
            showAcceptanceHint: resolvedShowAcceptanceHint,
            disabledAppRules: resolvedDisabledAppRules,
            customSuggestionTextColorHex: resolvedCustomSuggestionTextColorHex,
            ghostTextOpacity: resolvedGhostTextOpacity,
            ghostTextSizeMultiplier: resolvedGhostTextSizeMultiplier,
            selectedEngine: resolvedEngine,
            selectedWordCountPreset: resolvedWordCountPreset,
            isUsingCustomWordCountRange: resolvedUsingCustomWordCountRange,
            customWordCountLowWords: resolvedCustomRange.lowWords,
            customWordCountHighWords: resolvedCustomRange.highWords,
            isClipboardContextEnabled: resolvedClipboardContextEnabled,
            isFastModeEnabled: resolvedFastModeEnabled,
            suppressCompletionsOnTypo: resolvedSuppressCompletionsOnTypo,
            offerTypoCorrections: resolvedOfferTypoCorrections,
            isPerformanceTrackingEnabled: resolvedPerformanceTrackingEnabled,
            isMenuBarWordCountVisible: resolvedMenuBarWordCountVisible,
            mirrorPreference: resolvedMirrorPreference,
            userName: resolvedUserName,
            customRules: resolvedCustomRules,
            responseLanguages: resolvedResponseLanguages,
            extendedContext: resolvedExtendedContext,
            debounceMilliseconds: resolvedDebounceMilliseconds,
            focusPollIntervalMilliseconds: resolvedFocusPollIntervalMilliseconds,
            isMultiLineEnabled: resolvedMultiLineEnabled,
            isEmojiPickerEnabled: resolvedEmojiPickerEnabled,
            isMacroExpansionEnabled: resolvedMacroExpansionEnabled,
            preferredEmojiSkinTone: resolvedPreferredEmojiSkinTone,
            preferredEmojiGender: resolvedPreferredEmojiGender,
            autoAcceptTrailingPunctuation: resolvedAutoAcceptTrailingPunctuation,
            acceptanceKeyCode: resolvedAcceptanceKeyCode,
            acceptanceKeyModifiers: resolvedAcceptanceKeyModifiers,
            acceptanceKeyLabel: resolvedAcceptanceKeyLabel,
            fullAcceptanceKeyCode: resolvedFullAcceptanceKeyCode,
            fullAcceptanceKeyModifiers: resolvedFullAcceptanceKeyModifiers,
            fullAcceptanceKeyLabel: resolvedFullAcceptanceKeyLabel,
            globalToggleKeyCode: resolvedGlobalToggleKeyCode,
            globalToggleKeyModifiers: resolvedGlobalToggleKeyModifiers,
            globalToggleKeyLabel: resolvedGlobalToggleKeyLabel,
            acceptanceGranularity: resolvedAcceptanceGranularity,
            isPowerBasedModelSwitchingEnabled: resolvedPowerBasedModelSwitchingEnabled,
            batteryEngine: resolvedBatteryEngine,
            batteryModelFilename: resolvedBatteryModelFilename,
            pluggedInEngine: resolvedPluggedInEngine,
            pluggedInModelFilename: resolvedPluggedInModelFilename
        )

        // Unconditional write-back so the resolved (possibly migrated or default-capped) values are
        // sticky on the next launch. Mirrors the resolution above field-for-field.
        saveGloballyEnabled(data.isGloballyEnabled)
        saveDisabledAppRules(data.disabledAppRules)
        saveShowIndicator(data.showIndicator)
        saveShowAcceptanceHint(data.showAcceptanceHint)
        saveCustomSuggestionTextColorHex(data.customSuggestionTextColorHex)
        saveGhostTextOpacity(data.ghostTextOpacity)
        saveGhostTextSizeMultiplier(data.ghostTextSizeMultiplier)
        saveSelectedEngine(data.selectedEngine)
        saveSelectedWordCountPreset(data.selectedWordCountPreset)
        saveUsingCustomWordCountRange(data.isUsingCustomWordCountRange)
        saveCustomWordCountRange(low: data.customWordCountLowWords, high: data.customWordCountHighWords)
        saveClipboardContextEnabled(data.isClipboardContextEnabled)
        saveFastModeEnabled(data.isFastModeEnabled)
        saveSuppressCompletionsOnTypo(data.suppressCompletionsOnTypo)
        saveOfferTypoCorrections(data.offerTypoCorrections)
        savePerformanceTrackingEnabled(data.isPerformanceTrackingEnabled)
        saveMenuBarWordCountVisible(data.isMenuBarWordCountVisible)
        saveMirrorPreference(data.mirrorPreference)
        saveUserName(data.userName)
        saveCustomRules(data.customRules)
        saveExtendedContext(data.extendedContext)
        saveResponseLanguages(data.responseLanguages)
        saveDebounceMilliseconds(data.debounceMilliseconds)
        saveFocusPollIntervalMilliseconds(data.focusPollIntervalMilliseconds)
        saveMultiLineEnabled(data.isMultiLineEnabled)
        saveEmojiPickerEnabled(data.isEmojiPickerEnabled)
        saveMacroExpansionEnabled(data.isMacroExpansionEnabled)
        savePreferredEmojiSkinTone(data.preferredEmojiSkinTone)
        savePreferredEmojiGender(data.preferredEmojiGender)
        saveAutoAcceptTrailingPunctuation(data.autoAcceptTrailingPunctuation)
        saveAcceptanceKey(
            keyCode: data.acceptanceKeyCode,
            modifiers: data.acceptanceKeyModifiers,
            label: data.acceptanceKeyLabel
        )
        saveFullAcceptanceKey(
            keyCode: data.fullAcceptanceKeyCode,
            modifiers: data.fullAcceptanceKeyModifiers,
            label: data.fullAcceptanceKeyLabel
        )
        saveGlobalToggleKey(
            keyCode: data.globalToggleKeyCode,
            modifiers: data.globalToggleKeyModifiers,
            label: data.globalToggleKeyLabel
        )
        saveAcceptanceGranularity(data.acceptanceGranularity)
        savePowerBasedModelSwitchingEnabled(data.isPowerBasedModelSwitchingEnabled)
        saveBatteryEngine(data.batteryEngine)
        saveBatteryModelFilename(data.batteryModelFilename)
        savePluggedInEngine(data.pluggedInEngine)
        savePluggedInModelFilename(data.pluggedInModelFilename)

        // The custom indicator icon feature was removed; scrub any previously-persisted PNG so
        // users who picked one in an older build get the default cat icon back automatically.
        userDefaults.removeObject(forKey: "cotabbyCustomIndicatorImageData")

        return data
    }

    // MARK: - Save (one method per field; the facade routes its setters through these)

    func saveGloballyEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: Self.isGloballyEnabledDefaultsKey)
    }

    func saveDisabledAppRules(_ rules: [DisabledApplicationRule]) {
        guard !rules.isEmpty else {
            userDefaults.removeObject(forKey: Self.disabledAppRulesDefaultsKey)
            return
        }

        if let data = try? JSONEncoder().encode(rules) {
            userDefaults.set(data, forKey: Self.disabledAppRulesDefaultsKey)
        }
    }

    func saveShowIndicator(_ show: Bool) {
        let mode: ActivationIndicatorMode = show ? .fieldEdgeIcon : .hidden
        userDefaults.set(mode.rawValue, forKey: Self.selectedIndicatorModeDefaultsKey)
        userDefaults.set(show, forKey: Self.showCaretIndicatorDefaultsKey)
    }

    func saveShowAcceptanceHint(_ show: Bool) {
        userDefaults.set(show, forKey: Self.showAcceptanceHintDefaultsKey)
    }

    func saveCustomSuggestionTextColorHex(_ hex: String?) {
        if let hex {
            userDefaults.set(hex, forKey: Self.customSuggestionTextColorHexDefaultsKey)
        } else {
            userDefaults.removeObject(forKey: Self.customSuggestionTextColorHexDefaultsKey)
        }
    }

    func saveGhostTextOpacity(_ opacity: Double) {
        userDefaults.set(opacity, forKey: Self.ghostTextOpacityDefaultsKey)
    }

    func saveGhostTextSizeMultiplier(_ multiplier: Double) {
        userDefaults.set(multiplier, forKey: Self.ghostTextSizeMultiplierDefaultsKey)
    }

    func saveSelectedEngine(_ engine: SuggestionEngineKind) {
        userDefaults.set(engine.rawValue, forKey: Self.selectedEngineDefaultsKey)
    }

    func savePowerBasedModelSwitchingEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: Self.powerModelSwitchingEnabledDefaultsKey)
    }

    func saveBatteryEngine(_ engine: SuggestionEngineKind) {
        userDefaults.set(engine.rawValue, forKey: Self.batteryEngineDefaultsKey)
    }

    func saveBatteryModelFilename(_ filename: String) {
        userDefaults.set(filename, forKey: Self.batteryModelFilenameDefaultsKey)
    }

    func savePluggedInEngine(_ engine: SuggestionEngineKind) {
        userDefaults.set(engine.rawValue, forKey: Self.pluggedInEngineDefaultsKey)
    }

    func savePluggedInModelFilename(_ filename: String) {
        userDefaults.set(filename, forKey: Self.pluggedInModelFilenameDefaultsKey)
    }

    func saveSelectedWordCountPreset(_ preset: SuggestionWordCountPreset) {
        userDefaults.set(preset.rawValue, forKey: Self.selectedWordCountPresetDefaultsKey)
    }

    func saveUsingCustomWordCountRange(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: Self.usingCustomWordCountRangeDefaultsKey)
    }

    func saveCustomWordCountRange(low: Int, high: Int) {
        let normalized = SuggestionWordRange.clamped(low: low, high: high)
        userDefaults.set(normalized.lowWords, forKey: Self.customWordCountLowWordsDefaultsKey)
        userDefaults.set(normalized.highWords, forKey: Self.customWordCountHighWordsDefaultsKey)
    }

    func saveClipboardContextEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: Self.clipboardContextEnabledDefaultsKey)
    }

    func saveFastModeEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: Self.fastModeEnabledDefaultsKey)
    }

    func saveSuppressCompletionsOnTypo(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: Self.suppressCompletionsOnTypoDefaultsKey)
    }

    func saveOfferTypoCorrections(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: Self.offerTypoCorrectionsDefaultsKey)
    }

    func savePerformanceTrackingEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: Self.performanceTrackingEnabledDefaultsKey)
    }

    func saveMenuBarWordCountVisible(_ visible: Bool) {
        userDefaults.set(visible, forKey: Self.menuBarWordCountVisibleDefaultsKey)
    }

    func saveMirrorPreference(_ preference: MirrorPreference) {
        userDefaults.set(preference.rawValue, forKey: Self.mirrorPreferenceDefaultsKey)
    }

    func saveUserName(_ name: String) {
        userDefaults.set(name, forKey: Self.userNameDefaultsKey)
    }

    func saveCustomRules(_ rules: [String]) {
        userDefaults.set(rules, forKey: Self.customRulesDefaultsKey)
    }

    func saveResponseLanguages(_ languages: [String]) {
        userDefaults.set(languages, forKey: Self.responseLanguagesDefaultsKey)
    }

    func saveExtendedContext(_ context: String) {
        if context.isEmpty {
            userDefaults.removeObject(forKey: Self.extendedContextDefaultsKey)
        } else {
            userDefaults.set(context, forKey: Self.extendedContextDefaultsKey)
        }
    }

    func saveDebounceMilliseconds(_ value: Int) {
        userDefaults.set(value, forKey: Self.debounceMillisecondsDefaultsKey)
    }

    func saveFocusPollIntervalMilliseconds(_ value: Int) {
        userDefaults.set(value, forKey: Self.focusPollIntervalMillisecondsDefaultsKey)
    }

    func saveMultiLineEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: Self.multiLineEnabledDefaultsKey)
    }

    func saveEmojiPickerEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: Self.emojiPickerEnabledDefaultsKey)
    }

    func saveMacroExpansionEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: Self.macroExpansionEnabledDefaultsKey)
    }

    func savePreferredEmojiSkinTone(_ tone: EmojiSkinTone) {
        userDefaults.set(tone.rawValue, forKey: Self.preferredEmojiSkinToneDefaultsKey)
    }

    func savePreferredEmojiGender(_ gender: EmojiGender) {
        userDefaults.set(gender.rawValue, forKey: Self.preferredEmojiGenderDefaultsKey)
    }

    func saveAutoAcceptTrailingPunctuation(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: Self.autoAcceptTrailingPunctuationDefaultsKey)
    }

    func saveAcceptanceKey(keyCode: CGKeyCode, modifiers: ShortcutModifierMask, label: String) {
        userDefaults.set(Int(keyCode), forKey: Self.acceptanceKeyCodeDefaultsKey)
        userDefaults.set(Int(modifiers.rawValue), forKey: Self.acceptanceKeyModifiersDefaultsKey)
        userDefaults.set(label, forKey: Self.acceptanceKeyLabelDefaultsKey)
    }

    func saveFullAcceptanceKey(keyCode: CGKeyCode, modifiers: ShortcutModifierMask, label: String) {
        userDefaults.set(Int(keyCode), forKey: Self.fullAcceptanceKeyCodeDefaultsKey)
        userDefaults.set(Int(modifiers.rawValue), forKey: Self.fullAcceptanceKeyModifiersDefaultsKey)
        userDefaults.set(label, forKey: Self.fullAcceptanceKeyLabelDefaultsKey)
    }

    func saveGlobalToggleKey(keyCode: CGKeyCode, modifiers: ShortcutModifierMask, label: String) {
        userDefaults.set(Int(keyCode), forKey: Self.globalToggleKeyCodeDefaultsKey)
        userDefaults.set(Int(modifiers.rawValue), forKey: Self.globalToggleKeyModifiersDefaultsKey)
        userDefaults.set(label, forKey: Self.globalToggleKeyLabelDefaultsKey)
    }

    func saveAcceptanceGranularity(_ granularity: AcceptanceGranularity) {
        userDefaults.set(granularity.rawValue, forKey: Self.acceptanceGranularityDefaultsKey)
    }

    // MARK: - Disabled-app rule decoding

    private func loadDisabledAppRules() -> [DisabledApplicationRule] {
        guard let data = userDefaults.data(forKey: Self.disabledAppRulesDefaultsKey),
              let decodedRules = try? JSONDecoder().decode([DisabledApplicationRule].self, from: data)
        else {
            return []
        }

        return Self.sanitizedDisabledAppRules(decodedRules)
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

    // MARK: - Pure value normalizers (shared with the facade's setters)

    static func sortedDisabledAppRules(
        _ rules: [DisabledApplicationRule]
    ) -> [DisabledApplicationRule] {
        rules.sorted {
            if $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedSame {
                return $0.bundleIdentifier < $1.bundleIdentifier
            }

            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    static func normalizedBundleIdentifier(_ bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier else {
            return nil
        }

        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedDisplayName(
        _ displayName: String,
        fallbackBundleIdentifier: String
    ) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackBundleIdentifier : trimmed
    }

    static func clampedGhostTextOpacity(_ value: Double) -> Double {
        guard value.isFinite else {
            return defaultGhostTextOpacity
        }

        return min(maximumGhostTextOpacity, max(minimumGhostTextOpacity, value))
    }

    static func clampedGhostTextSizeMultiplier(_ value: Double) -> Double {
        guard value.isFinite else {
            return defaultGhostTextSizeMultiplier
        }

        return min(maximumGhostTextSizeMultiplier, max(minimumGhostTextSizeMultiplier, value))
    }

    static func normalizedHexString(_ hex: String?) -> String? {
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

    /// Length-cap the persisted body at `maximumExtendedContextCharacters` so an accidental paste
    /// of a huge document can't blow out the model's context window on every subsequent request.
    ///
    /// Whitespace is intentionally NOT trimmed here. The TextEditor binding writes back through
    /// `setExtendedContext` on every keystroke, so any trim — including a trailing-space trim —
    /// would strip whitespace the user is mid-way through typing, making it impossible to type a
    /// space at the end of a word. Whitespace-only content is collapsed back to "no value" in
    /// `SuggestionRequestFactory` instead, where the cost is paid once per request rather than once
    /// per keystroke.
    static func normalizedExtendedContext(_ context: String) -> String {
        guard context.count > maximumExtendedContextCharacters else {
            return context
        }
        return String(context.prefix(maximumExtendedContextCharacters))
    }
}
