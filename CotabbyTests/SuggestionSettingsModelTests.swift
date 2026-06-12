import Combine
import CoreGraphics
import XCTest
@testable import Cotabby

/// Locks the settings facade: every setter persists through the store (so a fresh model reload
/// sees the value), every guard makes repeat writes no-ops, and the cross-field policies
/// (keybinding conflicts, hint-label fallback, power-profile seeding) hold. The pure store is
/// tested in isolation in `SuggestionSettingsStoreTests`; these tests cover the facade wiring,
/// which is exactly the layer a renamed defaults key or a dropped save call would break.
@MainActor
final class SuggestionSettingsModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "cotabby.test.settingsModel.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeModel() -> SuggestionSettingsModel {
        SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
    }

    // MARK: - Setter persistence round-trip

    func test_setters_persistThroughStoreAndReloadInAFreshModel() {
        let model = makeModel()

        // Each setter runs twice with the same value: the first call exercises the mutate+save
        // path, the second the same-value guard. A silent guard regression (saving anyway) is
        // invisible here, but a broken save or a load/save key mismatch fails the reload below.
        for _ in 0..<2 {
            model.setGloballyEnabled(false)
            model.selectEngine(.appleIntelligence)
            model.selectWordCountPreset(.twelveToTwenty)
            model.setUsingCustomWordCountRange(true)
            model.setCustomWordCountRange(low: 3, high: 9)
            model.setClipboardContextEnabled(false)
            model.setFastModeEnabled(true)
            model.setSuppressCompletionsOnTypo(true)
            model.setOfferTypoCorrections(true)
            model.setAutomaticallyFixTypos(true)
            model.setPerformanceTrackingEnabled(true)
            model.setMenuBarWordCountVisible(false)
            model.setMirrorPreference(.alwaysMirror)
            model.setMultiLineEnabled(true)
            model.setEmojiPickerEnabled(false)
            model.setMacroExpansionEnabled(false)
            model.setPreferredEmojiSkinTone(.mediumDark)
            model.setPreferredEmojiGender(.female)
            model.setAutoAcceptTrailingPunctuation(false)
            model.setAcceptanceGranularity(.phrase)
            model.setSuggestInIntegratedTerminals(true)
            model.setShowIndicator(false)
            model.setShowAcceptanceHint(false)
            model.setUserName("Ada")
            model.setExtendedContext("Glossary: cotabby means tea whisk")
            model.setGhostTextOpacity(SuggestionSettingsModel.minimumGhostTextOpacity)
            model.setGhostTextSizeMultiplier(SuggestionSettingsModel.maximumGhostTextSizeMultiplier)
            model.setCustomSuggestionTextColorHex("#a1b2c3")
            model.setPowerBasedModelSwitchingEnabled(true)
            model.setBatteryEngine(.appleIntelligence)
            model.setBatteryModelFilename("small.gguf")
            model.setPluggedInEngine(.llamaOpenSource)
            model.setPluggedInModelFilename("big.gguf")
        }

        let reloaded = makeModel()
        XCTAssertFalse(reloaded.isGloballyEnabled)
        XCTAssertEqual(reloaded.selectedEngine, .appleIntelligence)
        XCTAssertEqual(reloaded.selectedWordCountPreset, .twelveToTwenty)
        XCTAssertTrue(reloaded.isUsingCustomWordCountRange)
        XCTAssertEqual(reloaded.customWordCountLowWords, 3)
        XCTAssertEqual(reloaded.customWordCountHighWords, 9)
        XCTAssertFalse(reloaded.isClipboardContextEnabled)
        XCTAssertTrue(reloaded.isFastModeEnabled)
        XCTAssertTrue(reloaded.suppressCompletionsOnTypo)
        XCTAssertTrue(reloaded.offerTypoCorrections)
        XCTAssertTrue(reloaded.automaticallyFixTypos)
        XCTAssertTrue(reloaded.isPerformanceTrackingEnabled)
        XCTAssertFalse(reloaded.isMenuBarWordCountVisible)
        XCTAssertEqual(reloaded.mirrorPreference, .alwaysMirror)
        XCTAssertTrue(reloaded.isMultiLineEnabled)
        XCTAssertFalse(reloaded.isEmojiPickerEnabled)
        XCTAssertFalse(reloaded.isMacroExpansionEnabled)
        XCTAssertEqual(reloaded.preferredEmojiSkinTone, .mediumDark)
        XCTAssertEqual(reloaded.preferredEmojiGender, .female)
        XCTAssertFalse(reloaded.autoAcceptTrailingPunctuation)
        XCTAssertEqual(reloaded.acceptanceGranularity, .phrase)
        XCTAssertTrue(reloaded.suggestInIntegratedTerminals)
        XCTAssertFalse(reloaded.showIndicator)
        XCTAssertFalse(reloaded.showCaretIndicator)
        XCTAssertFalse(reloaded.showAcceptanceHint)
        XCTAssertEqual(reloaded.userName, "Ada")
        XCTAssertEqual(reloaded.extendedContext, "Glossary: cotabby means tea whisk")
        XCTAssertEqual(reloaded.ghostTextOpacity, SuggestionSettingsModel.minimumGhostTextOpacity)
        XCTAssertEqual(reloaded.ghostTextSizeMultiplier, SuggestionSettingsModel.maximumGhostTextSizeMultiplier)
        XCTAssertEqual(reloaded.customSuggestionTextColorHex, "A1B2C3")
        XCTAssertTrue(reloaded.isPowerBasedModelSwitchingEnabled)
        XCTAssertEqual(reloaded.batteryEngine, .appleIntelligence)
        XCTAssertEqual(reloaded.batteryModelFilename, "small.gguf")
        XCTAssertEqual(reloaded.pluggedInEngine, .llamaOpenSource)
        XCTAssertEqual(reloaded.pluggedInModelFilename, "big.gguf")
    }

    // MARK: - Power profiles

    func test_powerProfiles_mapEngineAndFilenameIntoProfileValues() {
        let model = makeModel()
        model.setBatteryEngine(.appleIntelligence)
        model.setPluggedInEngine(.llamaOpenSource)
        model.setPluggedInModelFilename("qwen.gguf")

        XCTAssertEqual(model.batteryProfile, .appleIntelligence)
        XCTAssertEqual(model.pluggedInProfile, .llama(filename: "qwen.gguf"))
    }

    func test_setPowerProfiles_applyEngineAndLlamaFilename() {
        let model = makeModel()

        model.setBatteryProfile(.llama(filename: "tiny.gguf"))
        XCTAssertEqual(model.batteryEngine, .llamaOpenSource)
        XCTAssertEqual(model.batteryModelFilename, "tiny.gguf")

        // Switching to Apple Intelligence keeps the stored llama filename so flipping back does
        // not lose the previous model choice.
        model.setPluggedInProfile(.llama(filename: "large.gguf"))
        model.setPluggedInProfile(.appleIntelligence)
        XCTAssertEqual(model.pluggedInEngine, .appleIntelligence)
        XCTAssertEqual(model.pluggedInModelFilename, "large.gguf")
    }

    func test_initializePowerProfiles_seedsOnlyPristineProfiles() {
        let model = makeModel()

        // Battery profile made non-pristine by an explicit engine choice; plugged-in stays pristine.
        model.setBatteryEngine(.appleIntelligence)
        model.initializePowerProfiles(currentEngine: .llamaOpenSource, currentModelFilename: "active.gguf")

        XCTAssertEqual(model.batteryEngine, .appleIntelligence, "an explicit choice must never be reseeded")
        XCTAssertEqual(model.batteryModelFilename, "")
        XCTAssertEqual(model.pluggedInEngine, .llamaOpenSource)
        XCTAssertEqual(model.pluggedInModelFilename, "active.gguf")
    }

    func test_initializePowerProfiles_withNilFilenameSeedsEngineOnly() {
        let model = makeModel()
        model.initializePowerProfiles(currentEngine: .appleIntelligence, currentModelFilename: nil)

        XCTAssertEqual(model.batteryEngine, .appleIntelligence)
        XCTAssertEqual(model.batteryModelFilename, "")
        XCTAssertEqual(model.pluggedInEngine, .appleIntelligence)
        XCTAssertEqual(model.pluggedInModelFilename, "")
    }

    // MARK: - Spelling dictionaries

    func test_setSpellingDictionary_togglesMembershipAndPersists() {
        let model = makeModel()
        guard let language = SpellingDictionaryLanguage.allCases.first else {
            return XCTFail("Catalog has no languages")
        }

        model.setSpellingDictionary(language, enabled: false)
        XCTAssertFalse(model.isSpellingDictionaryEnabled(language))

        model.setSpellingDictionary(language, enabled: true)
        XCTAssertTrue(model.isSpellingDictionaryEnabled(language))
        XCTAssertTrue(makeModel().isSpellingDictionaryEnabled(language))
    }

    // MARK: - Disabled application rules

    func test_disableApplication_addsNormalizedRuleAndDedupesByBundleIdentifier() {
        let model = makeModel()

        model.disableApplication(bundleIdentifier: "  com.example.app  ", displayName: "   ")
        XCTAssertTrue(model.isApplicationDisabled(bundleIdentifier: "com.example.app"))
        // A blank display name falls back to the bundle identifier.
        XCTAssertEqual(model.disabledAppRules.first?.displayName, "com.example.app")

        // Re-disabling the same bundle replaces the rule instead of appending a duplicate.
        model.disableApplication(bundleIdentifier: "com.example.app", displayName: "Example")
        XCTAssertEqual(model.disabledAppRules.count, 1)
        XCTAssertEqual(model.disabledAppRules.first?.displayName, "Example")
    }

    func test_setApplicationDisabled_routesAddAndRemoveAndIgnoresInvalidBundles() {
        let model = makeModel()

        model.setApplicationDisabled(bundleIdentifier: nil, displayName: "Ghost", disabled: true)
        model.setApplicationDisabled(bundleIdentifier: "   ", displayName: "Blank", disabled: true)
        XCTAssertTrue(model.disabledAppRules.isEmpty)

        model.setApplicationDisabled(bundleIdentifier: "com.example.one", displayName: "One", disabled: true)
        XCTAssertTrue(model.isApplicationDisabled(bundleIdentifier: "com.example.one"))

        model.setApplicationDisabled(bundleIdentifier: "com.example.one", displayName: "One", disabled: false)
        XCTAssertFalse(model.isApplicationDisabled(bundleIdentifier: "com.example.one"))

        // Removing a bundle that was never disabled must not dirty the rule list.
        model.removeDisabledApplication(bundleIdentifier: "com.example.never")
        model.removeDisabledApplication(bundleIdentifier: nil)
        XCTAssertTrue(model.disabledAppRules.isEmpty)
    }

    func test_isApplicationDisabled_nilOrUnknownBundleIsNotDisabled() {
        let model = makeModel()
        XCTAssertFalse(model.isApplicationDisabled(bundleIdentifier: nil))
        XCTAssertFalse(model.isApplicationDisabled(bundleIdentifier: "com.example.unknown"))
    }

    // MARK: - Acceptance hint label

    func test_acceptanceHintLabel_prefersWordKeyThenFullKeyThenNil() {
        let model = makeModel()

        // Default state: word-accept key bound, hint shown.
        XCTAssertEqual(model.acceptanceHintLabel, model.acceptanceKeyLabel)

        // Word key cleared: the hint falls back to the full-accept key so it still teaches a
        // working gesture.
        model.clearAcceptanceKey()
        XCTAssertEqual(model.acceptanceHintLabel, model.fullAcceptanceKeyLabel)
        XCTAssertNil(model.emojiPickerAcceptKeyLabel)

        // Both cleared: nothing to teach.
        model.clearFullAcceptanceKey()
        XCTAssertNil(model.acceptanceHintLabel)
    }

    func test_acceptanceHintLabel_hiddenWhenHintDisabled() {
        let model = makeModel()
        model.setShowAcceptanceHint(false)
        XCTAssertNil(model.acceptanceHintLabel)
        // The emoji picker instruction is independent of the ghost-text hint toggle.
        XCTAssertEqual(model.emojiPickerAcceptKeyLabel, model.acceptanceKeyLabel)
    }

    // MARK: - Keybinding rules

    func test_setAcceptanceKey_stealingTheFullAcceptComboClearsFullAccept() {
        let model = makeModel()
        model.setFullAcceptanceKey(keyCode: 36, modifiers: [.command], label: "⌘Return")

        model.setAcceptanceKey(keyCode: 36, modifiers: [.command], label: "⌘Return")

        XCTAssertEqual(model.acceptanceKeyCode, 36)
        XCTAssertEqual(model.fullAcceptanceKeyCode, SuggestionSettingsModel.disabledKeyCode)
        XCTAssertEqual(model.fullAcceptanceKeyLabel, SuggestionSettingsModel.disabledKeyLabel)
    }

    func test_setFullAcceptanceKey_stealingTheAcceptComboClearsAccept() {
        let model = makeModel()
        model.setAcceptanceKey(keyCode: 48, modifiers: [], label: "Tab")

        model.setFullAcceptanceKey(keyCode: 48, modifiers: [], label: "Tab")

        XCTAssertEqual(model.fullAcceptanceKeyCode, 48)
        XCTAssertEqual(model.acceptanceKeyCode, SuggestionSettingsModel.disabledKeyCode)
    }

    func test_setAcceptanceKey_sameKeyDifferentModifiersCoexists() {
        // Tab and Shift-Tab are distinct bindings; only an exact (keyCode, modifiers) match is a
        // conflict.
        let model = makeModel()
        model.setFullAcceptanceKey(keyCode: 48, modifiers: [.shift], label: "⇧Tab")
        model.setAcceptanceKey(keyCode: 48, modifiers: [], label: "Tab")

        XCTAssertEqual(model.acceptanceKeyCode, 48)
        XCTAssertEqual(model.fullAcceptanceKeyCode, 48)
        XCTAssertEqual(model.fullAcceptanceKeyModifiers, [.shift])
    }

    func test_disabledKeyCode_normalizesModifiersToEmpty() {
        let model = makeModel()
        model.setAcceptanceKey(
            keyCode: SuggestionSettingsModel.disabledKeyCode,
            modifiers: [.command, .shift],
            label: SuggestionSettingsModel.disabledKeyLabel
        )
        XCTAssertEqual(model.acceptanceKeyModifiers, [])

        model.setGlobalToggleKey(
            keyCode: SuggestionSettingsModel.disabledKeyCode,
            modifiers: [.option],
            label: SuggestionSettingsModel.disabledKeyLabel
        )
        XCTAssertEqual(model.globalToggleKeyModifiers, [])
    }

    func test_globalToggleKey_setAndClearPersist() {
        let model = makeModel()
        model.setGlobalToggleKey(keyCode: 11, modifiers: [.command, .option], label: "⌘⌥B")

        let reloaded = makeModel()
        XCTAssertEqual(reloaded.globalToggleKeyCode, 11)
        XCTAssertEqual(reloaded.globalToggleKeyModifiers, [.command, .option])
        XCTAssertEqual(reloaded.globalToggleKeyLabel, "⌘⌥B")

        model.clearGlobalToggleKey()
        XCTAssertEqual(model.globalToggleKeyCode, SuggestionSettingsModel.disabledKeyCode)
        XCTAssertEqual(model.globalToggleKeyLabel, SuggestionSettingsModel.disabledKeyLabel)
    }

    func test_toggleGloballyEnabled_flipsAndPersists() {
        let model = makeModel()
        let initial = model.isGloballyEnabled

        model.toggleGloballyEnabled()
        XCTAssertEqual(model.isGloballyEnabled, !initial)
        XCTAssertEqual(makeModel().isGloballyEnabled, !initial)

        model.toggleGloballyEnabled()
        XCTAssertEqual(model.isGloballyEnabled, initial)
    }

    func test_shortcutActionDisplayNames_coverAllActions() {
        XCTAssertEqual(ShortcutAction.acceptWord.displayName, "Accept Word")
        XCTAssertEqual(ShortcutAction.acceptEntireSuggestion.displayName, "Accept Entire Suggestion")
        XCTAssertEqual(ShortcutAction.toggleTabby.displayName, "Toggle Tabby")
    }

    // MARK: - Normalization funnels

    func test_rules_addRemoveClearFunnelThroughNormalization() {
        let model = makeModel()

        model.addRule("  Always answer briefly.  ")
        model.addRule("Always answer briefly.")
        XCTAssertEqual(model.customRules, ["Always answer briefly."], "rules are trimmed and deduped")

        model.addRule("Prefer plain prose.")
        model.removeRule("Always answer briefly.")
        XCTAssertEqual(model.customRules, ["Prefer plain prose."])

        model.clearRules()
        XCTAssertEqual(model.customRules, CustomRulesCatalog.defaultRules)
    }

    func test_languages_addRemoveClearFunnelThroughNormalization() {
        let model = makeModel()

        model.addLanguage("French")
        model.addLanguage("French")
        XCTAssertEqual(model.responseLanguages.filter { $0 == "French" }.count, 1)

        model.removeLanguage("French")
        XCTAssertFalse(model.responseLanguages.contains("French"))

        model.addLanguage("Japanese")
        model.clearLanguages()
        XCTAssertEqual(model.responseLanguages, LanguageCatalog.defaultLanguages)
    }

    func test_setExtendedContext_capsLengthWithoutTrimmingInteriorWhitespace() {
        let model = makeModel()
        let oversized = String(repeating: "a", count: SuggestionSettingsModel.maximumExtendedContextCharacters + 500)

        model.setExtendedContext(oversized)
        XCTAssertEqual(model.extendedContext.count, SuggestionSettingsModel.maximumExtendedContextCharacters)

        // Trailing whitespace survives: the editor writes back on every keystroke and a trim would
        // make it impossible to type a space at the end of a word.
        model.setExtendedContext("note ")
        XCTAssertEqual(model.extendedContext, "note ")
    }

    // MARK: - Clamps

    func test_setCustomWordCountRange_clampsAndOrders() {
        let model = makeModel()

        model.setCustomWordCountRange(low: -10, high: 9_999)
        XCTAssertEqual(model.customWordCountLowWords, SuggestionWordRange.minimumWord)
        XCTAssertEqual(model.customWordCountHighWords, SuggestionWordRange.maximumWord)

        // An inverted pair snaps high up to low rather than crossing.
        model.setCustomWordCountRange(low: 20, high: 5)
        XCTAssertEqual(model.customWordCountLowWords, 20)
        XCTAssertEqual(model.customWordCountHighWords, 20)
    }

    func test_ghostTextAppearanceSetters_clampToDocumentedBounds() {
        let model = makeModel()

        model.setGhostTextOpacity(5.0)
        XCTAssertEqual(model.ghostTextOpacity, SuggestionSettingsModel.maximumGhostTextOpacity)
        model.setGhostTextOpacity(-1)
        XCTAssertEqual(model.ghostTextOpacity, SuggestionSettingsModel.minimumGhostTextOpacity)

        model.setGhostTextSizeMultiplier(100)
        XCTAssertEqual(model.ghostTextSizeMultiplier, SuggestionSettingsModel.maximumGhostTextSizeMultiplier)
        model.setGhostTextSizeMultiplier(0)
        XCTAssertEqual(model.ghostTextSizeMultiplier, SuggestionSettingsModel.minimumGhostTextSizeMultiplier)
    }

    func test_setCustomSuggestionTextColorHex_normalizesAndClears() {
        let model = makeModel()

        model.setCustomSuggestionTextColorHex("#a1b2c3")
        XCTAssertEqual(model.customSuggestionTextColorHex, "A1B2C3")

        model.setCustomSuggestionTextColorHex(nil)
        XCTAssertNil(model.customSuggestionTextColorHex)
    }

    // MARK: - Snapshot publisher

    func test_snapshotPublisher_emitsCurrentStateThenDistinctChangesOnly() {
        let model = makeModel()
        var snapshots: [SuggestionSettingsSnapshot] = []
        var cancellables = Set<AnyCancellable>()
        model.snapshotPublisher
            .sink { snapshots.append($0) }
            .store(in: &cancellables)

        XCTAssertEqual(snapshots.count, 1, "CombineLatest must emit the current state on subscribe")
        XCTAssertEqual(snapshots.last?.isGloballyEnabled, model.isGloballyEnabled)

        let countBeforeNoOp = snapshots.count
        model.setGloballyEnabled(model.isGloballyEnabled)
        XCTAssertEqual(snapshots.count, countBeforeNoOp, "a same-value write must not re-emit")

        model.setGloballyEnabled(!model.isGloballyEnabled)
        XCTAssertEqual(snapshots.count, countBeforeNoOp + 1)
        XCTAssertEqual(snapshots.last?.isGloballyEnabled, model.isGloballyEnabled)

        // A custom-range edit flows into the snapshot pre-clamped.
        model.setUsingCustomWordCountRange(true)
        model.setCustomWordCountRange(low: 2, high: 200)
        XCTAssertEqual(snapshots.last?.customWordCountRange, SuggestionWordRange(lowWords: 2, highWords: 50))
        XCTAssertEqual(snapshots.last?.isUsingCustomWordCountRange, true)
    }

    func test_snapshot_reflectsDisabledBundlesAndExtendedContext() {
        let model = makeModel()
        model.disableApplication(bundleIdentifier: "com.example.app", displayName: "Example")
        model.setExtendedContext("context body")

        let snapshot = model.snapshot
        XCTAssertEqual(snapshot.disabledAppBundleIdentifiers, ["com.example.app"])
        XCTAssertEqual(snapshot.extendedContext, "context body")
    }
}
