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
/// Owns the durable autocomplete preferences that are shared across the app: engine selection,
/// completion length, indicator appearance, and profile personalization.
///
/// This type is the right owner for these values because they are product settings, not
/// `SuggestionCoordinator` session state. The coordinator should react to settings changes, not
/// persist them itself.
///
/// It is a thin `@Published` facade: the durable values themselves live in the pure
/// `SuggestionSettingsData`, and all load / migrate / persist mechanics live in
/// `SuggestionSettingsStore` (which is unit-tested in isolation). The facade keeps the `@Published`
/// properties (so SwiftUI observation and the `$`-projected publishers keep working), applies the
/// cross-field keybinding rules, and routes each setter through the store.
@MainActor
final class SuggestionSettingsModel: ObservableObject {
    @Published private(set) var isGloballyEnabled: Bool
    @Published private(set) var showIndicator: Bool
    /// Whether the keycap hint (the small pill that teaches the accept key) is drawn after ghost text.
    @Published private(set) var showAcceptanceHint: Bool
    @Published private(set) var disabledAppRules: [DisabledApplicationRule]
    @Published private(set) var customSuggestionTextColorHex: String?
    @Published private(set) var ghostTextOpacity: Double
    /// Multiplier the overlay applies on top of the caret-approximated ghost-text size. Read live by
    /// `OverlayController` at present time (like `ghostTextOpacity`), so it is intentionally not part
    /// of the generation-facing `SuggestionSettingsSnapshot` — it changes presentation, not requests.
    @Published private(set) var ghostTextSizeMultiplier: Double
    @Published private(set) var selectedEngine: SuggestionEngineKind
    @Published private(set) var selectedWordCountPreset: SuggestionWordCountPreset
    /// When true, the active length budget reads `customWordCountLowWords...HighWords` and the
    /// curated `selectedWordCountPreset` is ignored for generation (but preserved as the value the
    /// picker snaps back to if the user turns Custom off again).
    @Published private(set) var isUsingCustomWordCountRange: Bool
    @Published private(set) var customWordCountLowWords: Int
    @Published private(set) var customWordCountHighWords: Int
    @Published private(set) var isClipboardContextEnabled: Bool
    @Published private(set) var isFastModeEnabled: Bool
    /// When on, a misspelled current word hides the normal continuation (see the typo gate).
    @Published private(set) var suppressCompletionsOnTypo: Bool
    /// When on (and `suppressCompletionsOnTypo` is also on), a misspelled current word is offered a
    /// green spell-checker correction the user can accept to replace the typo.
    @Published private(set) var offerTypoCorrections: Bool
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
    /// Whether the inline `/macro` preview is active. Read live by `MacroController` at event time,
    /// so toggling it takes effect on the next keystroke without restarting capture.
    @Published private(set) var isMacroExpansionEnabled: Bool
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
    @Published private(set) var isPowerBasedModelSwitchingEnabled: Bool
    @Published private(set) var batteryEngine: SuggestionEngineKind
    @Published private(set) var batteryModelFilename: String
    @Published private(set) var pluggedInEngine: SuggestionEngineKind
    @Published private(set) var pluggedInModelFilename: String

    /// Owns the on-disk keys, defaults, migrations, and per-field writes. The facade holds one and
    /// routes every load and save through it.
    private let store: SuggestionSettingsStore

    // Public default constants re-exported from `SuggestionSettingsStore` (the single source of
    // truth) so the Settings UI can keep referencing them as `SuggestionSettingsModel.X`.
    static let defaultAcceptanceKeyCode = SuggestionSettingsStore.defaultAcceptanceKeyCode
    static let defaultAcceptanceKeyLabel = SuggestionSettingsStore.defaultAcceptanceKeyLabel
    static let disabledKeyCode = SuggestionSettingsStore.disabledKeyCode
    static let disabledKeyLabel = SuggestionSettingsStore.disabledKeyLabel
    static let defaultFullAcceptanceKeyCode = SuggestionSettingsStore.defaultFullAcceptanceKeyCode
    static let defaultFullAcceptanceKeyLabel = SuggestionSettingsStore.defaultFullAcceptanceKeyLabel
    static let minimumGhostTextOpacity = SuggestionSettingsStore.minimumGhostTextOpacity
    static let maximumGhostTextOpacity = SuggestionSettingsStore.maximumGhostTextOpacity
    static let defaultGhostTextOpacity = SuggestionSettingsStore.defaultGhostTextOpacity
    static let ghostTextOpacityStep = SuggestionSettingsStore.ghostTextOpacityStep
    static let minimumGhostTextSizeMultiplier = SuggestionSettingsStore.minimumGhostTextSizeMultiplier
    static let maximumGhostTextSizeMultiplier = SuggestionSettingsStore.maximumGhostTextSizeMultiplier
    static let defaultGhostTextSizeMultiplier = SuggestionSettingsStore.defaultGhostTextSizeMultiplier
    static let ghostTextSizeMultiplierStep = SuggestionSettingsStore.ghostTextSizeMultiplierStep
    static let maximumExtendedContextCharacters = SuggestionSettingsStore.maximumExtendedContextCharacters

    init(
        configuration: SuggestionConfiguration,
        userDefaults: UserDefaults = .standard
    ) {
        let store = SuggestionSettingsStore(userDefaults: userDefaults)
        let data = store.load(configuration: configuration)
        self.store = store

        isGloballyEnabled = data.isGloballyEnabled
        showIndicator = data.showIndicator
        showAcceptanceHint = data.showAcceptanceHint
        disabledAppRules = data.disabledAppRules
        customSuggestionTextColorHex = data.customSuggestionTextColorHex
        ghostTextOpacity = data.ghostTextOpacity
        ghostTextSizeMultiplier = data.ghostTextSizeMultiplier
        selectedEngine = data.selectedEngine
        selectedWordCountPreset = data.selectedWordCountPreset
        isUsingCustomWordCountRange = data.isUsingCustomWordCountRange
        customWordCountLowWords = data.customWordCountLowWords
        customWordCountHighWords = data.customWordCountHighWords
        isClipboardContextEnabled = data.isClipboardContextEnabled
        isFastModeEnabled = data.isFastModeEnabled
        suppressCompletionsOnTypo = data.suppressCompletionsOnTypo
        offerTypoCorrections = data.offerTypoCorrections
        isPerformanceTrackingEnabled = data.isPerformanceTrackingEnabled
        isMenuBarWordCountVisible = data.isMenuBarWordCountVisible
        mirrorPreference = data.mirrorPreference
        userName = data.userName
        customRules = data.customRules
        responseLanguages = data.responseLanguages
        extendedContext = data.extendedContext
        debounceMilliseconds = data.debounceMilliseconds
        focusPollIntervalMilliseconds = data.focusPollIntervalMilliseconds
        isMultiLineEnabled = data.isMultiLineEnabled
        isEmojiPickerEnabled = data.isEmojiPickerEnabled
        isMacroExpansionEnabled = data.isMacroExpansionEnabled
        preferredEmojiSkinTone = data.preferredEmojiSkinTone
        preferredEmojiGender = data.preferredEmojiGender
        autoAcceptTrailingPunctuation = data.autoAcceptTrailingPunctuation
        acceptanceKeyCode = data.acceptanceKeyCode
        acceptanceKeyModifiers = data.acceptanceKeyModifiers
        acceptanceKeyLabel = data.acceptanceKeyLabel
        fullAcceptanceKeyCode = data.fullAcceptanceKeyCode
        fullAcceptanceKeyModifiers = data.fullAcceptanceKeyModifiers
        fullAcceptanceKeyLabel = data.fullAcceptanceKeyLabel
        globalToggleKeyCode = data.globalToggleKeyCode
        globalToggleKeyModifiers = data.globalToggleKeyModifiers
        globalToggleKeyLabel = data.globalToggleKeyLabel
        acceptanceGranularity = data.acceptanceGranularity
        isPowerBasedModelSwitchingEnabled = data.isPowerBasedModelSwitchingEnabled
        batteryEngine = data.batteryEngine
        batteryModelFilename = data.batteryModelFilename
        pluggedInEngine = data.pluggedInEngine
        pluggedInModelFilename = data.pluggedInModelFilename
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
            isUsingCustomWordCountRange: isUsingCustomWordCountRange,
            customWordCountRange: SuggestionWordRange.clamped(
                low: customWordCountLowWords,
                high: customWordCountHighWords
            ),
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
            acceptanceGranularity: acceptanceGranularity,
            suppressCompletionsOnTypo: suppressCompletionsOnTypo,
            offerTypoCorrections: offerTypoCorrections
        )
    }

    func selectEngine(_ engine: SuggestionEngineKind) {
        guard selectedEngine != engine else {
            return
        }

        selectedEngine = engine
        store.saveSelectedEngine(engine)
    }

    func setPowerBasedModelSwitchingEnabled(_ enabled: Bool) {
        guard isPowerBasedModelSwitchingEnabled != enabled else {
            return
        }

        isPowerBasedModelSwitchingEnabled = enabled
        store.savePowerBasedModelSwitchingEnabled(enabled)
    }

    func setBatteryEngine(_ engine: SuggestionEngineKind) {
        guard batteryEngine != engine else {
            return
        }

        batteryEngine = engine
        store.saveBatteryEngine(engine)
    }

    func setBatteryModelFilename(_ filename: String) {
        guard batteryModelFilename != filename else {
            return
        }

        batteryModelFilename = filename
        store.saveBatteryModelFilename(filename)
    }

    func setPluggedInEngine(_ engine: SuggestionEngineKind) {
        guard pluggedInEngine != engine else {
            return
        }

        pluggedInEngine = engine
        store.savePluggedInEngine(engine)
    }

    func setPluggedInModelFilename(_ filename: String) {
        guard pluggedInModelFilename != filename else {
            return
        }

        pluggedInModelFilename = filename
        store.savePluggedInModelFilename(filename)
    }

    /// The profile applied while on battery, assembled from the stored engine + model filename.
    var batteryProfile: PowerProfile {
        batteryEngine == .appleIntelligence ? .appleIntelligence : .llama(filename: batteryModelFilename)
    }

    /// The profile applied while plugged in, assembled from the stored engine + model filename.
    var pluggedInProfile: PowerProfile {
        pluggedInEngine == .appleIntelligence ? .appleIntelligence : .llama(filename: pluggedInModelFilename)
    }

    func setBatteryProfile(_ profile: PowerProfile) {
        setBatteryEngine(profile.engine)
        if case .llama(let filename) = profile {
            setBatteryModelFilename(filename)
        }
    }

    func setPluggedInProfile(_ profile: PowerProfile) {
        setPluggedInEngine(profile.engine)
        if case .llama(let filename) = profile {
            setPluggedInModelFilename(filename)
        }
    }

    /// Seeds each per-power-source profile from the active engine + model the first time the feature
    /// is configured, so the pickers default to something valid instead of an empty selection. Only
    /// seeds a profile still at its pristine default (Open Source with no model chosen), so an
    /// explicit Apple Intelligence or model choice is never overwritten on a later appearance.
    func initializePowerProfiles(currentEngine: SuggestionEngineKind, currentModelFilename: String?) {
        if batteryEngine == .llamaOpenSource, batteryModelFilename.isEmpty {
            setBatteryEngine(currentEngine)
            if let currentModelFilename {
                setBatteryModelFilename(currentModelFilename)
            }
        }

        if pluggedInEngine == .llamaOpenSource, pluggedInModelFilename.isEmpty {
            setPluggedInEngine(currentEngine)
            if let currentModelFilename {
                setPluggedInModelFilename(currentModelFilename)
            }
        }
    }

    func selectWordCountPreset(_ preset: SuggestionWordCountPreset) {
        guard selectedWordCountPreset != preset else {
            return
        }

        selectedWordCountPreset = preset
        store.saveSelectedWordCountPreset(preset)
    }

    /// Switches the active length budget between the curated preset and the user's custom range
    /// without overwriting either of the stored values, so flipping back and forth is idempotent.
    func setUsingCustomWordCountRange(_ enabled: Bool) {
        guard isUsingCustomWordCountRange != enabled else {
            return
        }
        isUsingCustomWordCountRange = enabled
        store.saveUsingCustomWordCountRange(enabled)
    }

    /// All custom-range mutations funnel through here so storage stays clamped to
    /// `[SuggestionWordRange.minimumWord, SuggestionWordRange.maximumWord]` with low <= high.
    func setCustomWordCountRange(low: Int, high: Int) {
        let normalized = SuggestionWordRange.clamped(low: low, high: high)
        guard customWordCountLowWords != normalized.lowWords
            || customWordCountHighWords != normalized.highWords
        else {
            return
        }
        customWordCountLowWords = normalized.lowWords
        customWordCountHighWords = normalized.highWords
        store.saveCustomWordCountRange(low: normalized.lowWords, high: normalized.highWords)
    }

    func setClipboardContextEnabled(_ enabled: Bool) {
        guard isClipboardContextEnabled != enabled else {
            return
        }

        isClipboardContextEnabled = enabled
        store.saveClipboardContextEnabled(enabled)
    }

    func setFastModeEnabled(_ enabled: Bool) {
        guard isFastModeEnabled != enabled else {
            return
        }

        isFastModeEnabled = enabled
        store.saveFastModeEnabled(enabled)
    }

    func setSuppressCompletionsOnTypo(_ enabled: Bool) {
        guard suppressCompletionsOnTypo != enabled else {
            return
        }

        suppressCompletionsOnTypo = enabled
        store.saveSuppressCompletionsOnTypo(enabled)
    }

    func setOfferTypoCorrections(_ enabled: Bool) {
        guard offerTypoCorrections != enabled else {
            return
        }

        offerTypoCorrections = enabled
        store.saveOfferTypoCorrections(enabled)
    }

    func setPerformanceTrackingEnabled(_ enabled: Bool) {
        guard isPerformanceTrackingEnabled != enabled else {
            return
        }

        isPerformanceTrackingEnabled = enabled
        store.savePerformanceTrackingEnabled(enabled)
    }

    func setMenuBarWordCountVisible(_ visible: Bool) {
        guard isMenuBarWordCountVisible != visible else {
            return
        }

        isMenuBarWordCountVisible = visible
        store.saveMenuBarWordCountVisible(visible)
    }

    func setMirrorPreference(_ preference: MirrorPreference) {
        guard mirrorPreference != preference else {
            return
        }

        mirrorPreference = preference
        store.saveMirrorPreference(preference)
    }

    func setMultiLineEnabled(_ enabled: Bool) {
        guard isMultiLineEnabled != enabled else {
            return
        }
        isMultiLineEnabled = enabled
        store.saveMultiLineEnabled(enabled)
    }

    func setEmojiPickerEnabled(_ enabled: Bool) {
        guard isEmojiPickerEnabled != enabled else {
            return
        }
        isEmojiPickerEnabled = enabled
        store.saveEmojiPickerEnabled(enabled)
    }

    func setMacroExpansionEnabled(_ enabled: Bool) {
        guard isMacroExpansionEnabled != enabled else {
            return
        }
        isMacroExpansionEnabled = enabled
        store.saveMacroExpansionEnabled(enabled)
    }

    func setPreferredEmojiSkinTone(_ tone: EmojiSkinTone) {
        guard preferredEmojiSkinTone != tone else { return }
        preferredEmojiSkinTone = tone
        store.savePreferredEmojiSkinTone(tone)
    }

    func setPreferredEmojiGender(_ gender: EmojiGender) {
        guard preferredEmojiGender != gender else { return }
        preferredEmojiGender = gender
        store.savePreferredEmojiGender(gender)
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
        store.saveAutoAcceptTrailingPunctuation(enabled)
    }

    func setAcceptanceGranularity(_ granularity: AcceptanceGranularity) {
        guard acceptanceGranularity != granularity else {
            return
        }
        acceptanceGranularity = granularity
        store.saveAcceptanceGranularity(granularity)
    }

    func setGloballyEnabled(_ enabled: Bool) {
        guard isGloballyEnabled != enabled else {
            return
        }

        isGloballyEnabled = enabled
        store.saveGloballyEnabled(enabled)
    }

    func setApplicationDisabled(
        bundleIdentifier: String?,
        displayName: String,
        disabled: Bool
    ) {
        guard let normalizedBundleIdentifier = SuggestionSettingsStore.normalizedBundleIdentifier(bundleIdentifier) else {
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
        guard let normalizedBundleIdentifier = SuggestionSettingsStore.normalizedBundleIdentifier(bundleIdentifier) else {
            return
        }

        let normalizedDisplayName = SuggestionSettingsStore.normalizedDisplayName(
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
        let updatedRules = SuggestionSettingsStore.sortedDisabledAppRules(Array(updatedRulesByBundleIdentifier.values))

        guard disabledAppRules != updatedRules else {
            return
        }

        disabledAppRules = updatedRules
        store.saveDisabledAppRules(updatedRules)
    }

    func removeDisabledApplication(bundleIdentifier: String?) {
        guard let normalizedBundleIdentifier = SuggestionSettingsStore.normalizedBundleIdentifier(bundleIdentifier)
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
        store.saveDisabledAppRules(updatedRules)
    }

    func isApplicationDisabled(bundleIdentifier: String?) -> Bool {
        guard let normalizedBundleIdentifier = SuggestionSettingsStore.normalizedBundleIdentifier(bundleIdentifier)
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
        store.saveShowIndicator(show)
    }

    func setShowAcceptanceHint(_ show: Bool) {
        guard showAcceptanceHint != show else {
            return
        }

        showAcceptanceHint = show
        store.saveShowAcceptanceHint(show)
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
        let normalizedHex = SuggestionSettingsStore.normalizedHexString(hex)
        guard customSuggestionTextColorHex != normalizedHex else {
            return
        }

        customSuggestionTextColorHex = normalizedHex
        store.saveCustomSuggestionTextColorHex(normalizedHex)
    }

    func setGhostTextOpacity(_ opacity: Double) {
        let clamped = SuggestionSettingsStore.clampedGhostTextOpacity(opacity)
        guard ghostTextOpacity != clamped else {
            return
        }

        ghostTextOpacity = clamped
        store.saveGhostTextOpacity(clamped)
    }

    func setGhostTextSizeMultiplier(_ multiplier: Double) {
        let clamped = SuggestionSettingsStore.clampedGhostTextSizeMultiplier(multiplier)
        guard ghostTextSizeMultiplier != clamped else {
            return
        }

        ghostTextSizeMultiplier = clamped
        store.saveGhostTextSizeMultiplier(clamped)
    }

    func setUserName(_ name: String) {
        guard userName != name else {
            return
        }

        userName = name
        store.saveUserName(name)
    }

    /// All rule mutations funnel through here so storage stays normalized (trimmed, deduped, capped).
    func setRules(_ rules: [String]) {
        let normalized = CustomRulesCatalog.normalize(rules)
        guard customRules != normalized else {
            return
        }

        customRules = normalized
        store.saveCustomRules(normalized)
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
        let normalized = SuggestionSettingsStore.normalizedExtendedContext(context)
        guard extendedContext != normalized else {
            return
        }

        extendedContext = normalized
        store.saveExtendedContext(normalized)
    }

    /// All language mutations funnel through here so storage stays normalized (trimmed, deduped,
    /// capped), mirroring `setRules`.
    func setLanguages(_ languages: [String]) {
        let normalized = LanguageCatalog.normalize(languages)
        guard responseLanguages != normalized else {
            return
        }

        responseLanguages = normalized
        store.saveResponseLanguages(normalized)
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
        store.saveAcceptanceKey(keyCode: keyCode, modifiers: normalizedModifiers, label: label)
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
        store.saveFullAcceptanceKey(keyCode: keyCode, modifiers: normalizedModifiers, label: label)
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
        store.saveGlobalToggleKey(keyCode: keyCode, modifiers: normalizedModifiers, label: label)
    }

    func clearGlobalToggleKey() {
        setGlobalToggleKey(keyCode: Self.disabledKeyCode, modifiers: [], label: Self.disabledKeyLabel)
    }

    // All stored state is thread-safe to release (Combine subjects, the value-typed store). The
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
            // Pair the two typo toggles into one inner publisher so the presentation slot stays at
            // Combine's four-upstream cap while still carrying both new fields.
            Publishers.CombineLatest4(
                $isClipboardContextEnabled,
                $isFastModeEnabled,
                $mirrorPreference,
                Publishers.CombineLatest($suppressCompletionsOnTypo, $offerTypoCorrections)
            ),
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
        // alongside `acceptanceGranularity` here for the same reason. The three custom-range fields
        // travel together as a single tuple so they only cost one slot in this outer layer.
        let customRange = Publishers.CombineLatest3(
            $isUsingCustomWordCountRange,
            $customWordCountLowWords,
            $customWordCountHighWords
        )
        return Publishers.CombineLatest4(primary, $acceptanceGranularity, $extendedContext, customRange)
            .map { primaryTuple, granularity, extendedContext, customRangeTuple in
                let (combinedSettings, presentationToggles, profile, timing) = primaryTuple
                let (globallyEnabled, disabledAppRules, engine, wordCountPreset) = combinedSettings
                let (clipboardContextEnabled, fastModeEnabled, mirrorPreference, typoToggles) = presentationToggles
                let (suppressOnTypo, offerCorrections) = typoToggles
                let (userName, customRules, responseLanguages) = profile
                let (debounce, focusPoll, multiLine, autoAcceptPunctuation) = timing
                let (isCustomActive, customLow, customHigh) = customRangeTuple
                return SuggestionSettingsSnapshot(
                    isGloballyEnabled: globallyEnabled,
                    disabledAppBundleIdentifiers: Set(disabledAppRules.map(\.bundleIdentifier)),
                    selectedEngine: engine,
                    selectedWordCountPreset: wordCountPreset,
                    isUsingCustomWordCountRange: isCustomActive,
                    customWordCountRange: SuggestionWordRange.clamped(low: customLow, high: customHigh),
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
                    acceptanceGranularity: granularity,
                    suppressCompletionsOnTypo: suppressOnTypo,
                    offerTypoCorrections: offerCorrections
                )
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}
