import ApplicationServices
import Combine
import Foundation

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
    /// How suggestions are presented (inline ghost text vs popup card vs auto).
    @Published private(set) var mirrorPreference: MirrorPreference
    @Published private(set) var userName: String
    @Published private(set) var customRules: [String]
    @Published private(set) var responseLanguages: [String]
    @Published private(set) var debounceMilliseconds: Int
    @Published private(set) var focusPollIntervalMilliseconds: Int
    @Published private(set) var isMultiLineEnabled: Bool
    @Published private(set) var autoAcceptTrailingPunctuation: Bool
    @Published private(set) var acceptanceKeyCode: CGKeyCode
    @Published private(set) var acceptanceKeyModifiers: ShortcutModifierMask
    @Published private(set) var acceptanceKeyLabel: String
    @Published private(set) var fullAcceptanceKeyCode: CGKeyCode
    @Published private(set) var fullAcceptanceKeyModifiers: ShortcutModifierMask
    @Published private(set) var fullAcceptanceKeyLabel: String
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
    private static let clipboardContextEnabledDefaultsKey = "cotabbyClipboardContextEnabled"
    private static let fastModeEnabledDefaultsKey = "cotabbyFastModeEnabled"
    private static let mirrorPreferenceDefaultsKey = "cotabbyMirrorPreference"
    private static let userNameDefaultsKey = "cotabbyUserName"
    private static let customRulesDefaultsKey = "cotabbyCustomRules"
    private static let responseLanguagesDefaultsKey = "cotabbyResponseLanguages"
    /// Legacy single-select key, read once to migrate the previous value into `responseLanguages`.
    private static let legacyResponseLanguageDefaultsKey = "cotabbyResponseLanguage"
    private static let debounceMillisecondsDefaultsKey = "cotabbyDebounceMilliseconds"
    private static let focusPollIntervalMillisecondsDefaultsKey = "cotabbyFocusPollIntervalMilliseconds"
    private static let multiLineEnabledDefaultsKey = "cotabbyMultiLineEnabled"
    private static let autoAcceptTrailingPunctuationDefaultsKey = "cotabbyAutoAcceptTrailingPunctuation"
    private static let acceptanceKeyCodeDefaultsKey = "cotabbyAcceptanceKeyCode"
    private static let acceptanceKeyModifiersDefaultsKey = "cotabbyAcceptanceKeyModifiers"
    private static let acceptanceKeyLabelDefaultsKey = "cotabbyAcceptanceKeyLabel"
    private static let fullAcceptanceKeyCodeDefaultsKey = "cotabbyFullAcceptanceKeyCode"
    private static let fullAcceptanceKeyModifiersDefaultsKey = "cotabbyFullAcceptanceKeyModifiers"
    private static let fullAcceptanceKeyLabelDefaultsKey = "cotabbyFullAcceptanceKeyLabel"

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
        let resolvedWordCountPreset = userDefaults
            .string(forKey: Self.selectedWordCountPresetDefaultsKey)
            .flatMap(SuggestionWordCountPreset.init(rawValue:))
            ?? configuration.defaultWordCountPreset
        let resolvedClipboardContextEnabled =
            userDefaults.object(forKey: Self.clipboardContextEnabledDefaultsKey) as? Bool ?? false
        // Defaults to false so the visual-context pipeline keeps running for existing users; opting
        // into fast mode turns it off.
        let resolvedFastModeEnabled =
            userDefaults.object(forKey: Self.fastModeEnabledDefaultsKey) as? Bool ?? false
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
            return max(10, min(500, raw))
        }()
        let resolvedFocusPollIntervalMilliseconds: Int = {
            let raw = userDefaults.object(forKey: Self.focusPollIntervalMillisecondsDefaultsKey) as? Int
                ?? configuration.focusPollIntervalMilliseconds
            // Existing installs may have the old 50ms first-launch default persisted. Floor at the
            // shipped default so the hotfix bump reaches them — the stepper is hidden from the UI,
            // so the persisted value is always the previous default, never a user-chosen override.
            let floored = max(raw, configuration.focusPollIntervalMilliseconds)
            return max(10, min(500, floored))
        }()

        let resolvedMultiLineEnabled = userDefaults.object(forKey: Self.multiLineEnabledDefaultsKey) as? Bool ?? false
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
        mirrorPreference = resolvedMirrorPreference
        userName = resolvedUserName
        customRules = resolvedCustomRules
        responseLanguages = resolvedResponseLanguages
        debounceMilliseconds = resolvedDebounceMilliseconds
        focusPollIntervalMilliseconds = resolvedFocusPollIntervalMilliseconds
        isMultiLineEnabled = resolvedMultiLineEnabled
        autoAcceptTrailingPunctuation = resolvedAutoAcceptTrailingPunctuation
        acceptanceKeyCode = resolvedAcceptanceKeyCode
        acceptanceKeyModifiers = resolvedAcceptanceKeyModifiers
        acceptanceKeyLabel = resolvedAcceptanceKeyLabel
        fullAcceptanceKeyCode = resolvedFullAcceptanceKeyCode
        fullAcceptanceKeyModifiers = resolvedFullAcceptanceKeyModifiers
        fullAcceptanceKeyLabel = resolvedFullAcceptanceKeyLabel

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
        persistMirrorPreference(resolvedMirrorPreference)
        persistUserName(resolvedUserName)
        persistCustomRules(resolvedCustomRules)
        persistResponseLanguages(resolvedResponseLanguages)
        userDefaults.set(resolvedDebounceMilliseconds, forKey: Self.debounceMillisecondsDefaultsKey)
        userDefaults.set(resolvedFocusPollIntervalMilliseconds, forKey: Self.focusPollIntervalMillisecondsDefaultsKey)
        userDefaults.set(resolvedMultiLineEnabled, forKey: Self.multiLineEnabledDefaultsKey)
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
            responseLanguages: responseLanguages,
            debounceMilliseconds: debounceMilliseconds,
            focusPollIntervalMilliseconds: focusPollIntervalMilliseconds,
            isMultiLineEnabled: isMultiLineEnabled,
            autoAcceptTrailingPunctuation: autoAcceptTrailingPunctuation,
            isFastModeEnabled: isFastModeEnabled,
            mirrorPreference: mirrorPreference
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

    func setAutoAcceptTrailingPunctuation(_ enabled: Bool) {
        guard autoAcceptTrailingPunctuation != enabled else {
            return
        }
        autoAcceptTrailingPunctuation = enabled
        userDefaults.set(enabled, forKey: Self.autoAcceptTrailingPunctuationDefaultsKey)
    }

    func setDebounceMilliseconds(_ value: Int) {
        let clamped = max(10, min(500, value))
        guard debounceMilliseconds != clamped else {
            return
        }

        debounceMilliseconds = clamped
        userDefaults.set(clamped, forKey: Self.debounceMillisecondsDefaultsKey)
    }

    func setFocusPollIntervalMilliseconds(_ value: Int) {
        let clamped = max(10, min(500, value))
        guard focusPollIntervalMilliseconds != clamped else {
            return
        }

        focusPollIntervalMilliseconds = clamped
        userDefaults.set(clamped, forKey: Self.focusPollIntervalMillisecondsDefaultsKey)
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
        Publishers.CombineLatest4(
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
        .map { combinedSettings, presentationToggles, profile, timing in
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
                responseLanguages: responseLanguages,
                debounceMilliseconds: debounce,
                focusPollIntervalMilliseconds: focusPoll,
                isMultiLineEnabled: multiLine,
                autoAcceptTrailingPunctuation: autoAcceptPunctuation,
                isFastModeEnabled: fastModeEnabled,
                mirrorPreference: mirrorPreference
            )
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }
}
