import XCTest
@testable import Cotabby

/// Direct tests for `SuggestionSettingsStore`, the load / migrate / persist engine extracted out of
/// the `@MainActor` `SuggestionSettingsModel` facade.
///
/// These exercise the correctness-sensitive migrations against an injected `UserDefaults` suite
/// without standing up the `ObservableObject`, so a regression in a migration (which would silently
/// strand an existing user's settings across an app update) fails here loudly. Key strings are
/// hardcoded on purpose: they mirror the store's private defaults keys, so a rename that would orphan
/// existing users trips a test.
@MainActor
final class SuggestionSettingsStoreTests: XCTestCase {

    // These run `async` (despite not awaiting) to match the other app-hosted tests: a synchronous
    // @MainActor test blocks the main actor while the host app is still doing its own main-actor
    // startup, which can crash the native runtime. Yielding cooperatively avoids that.

    // MARK: - Word-count preset migration (#475)

    func test_load_migratesRetiredShortPresetToFourToSeven() async {
        let defaults = makeIsolatedDefaults()
        defaults.set("3-7", forKey: "cotabbySelectedWordCountPreset")

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        XCTAssertEqual(data.selectedWordCountPreset, .fourToSeven)
    }

    // MARK: - Indicator mode vs legacy bool

    func test_load_prefersIndicatorModeOverLegacyBool() async {
        let defaults = makeIsolatedDefaults()
        // Conflicting values: the newer mode key says hidden, the legacy bool says shown. The mode
        // key must win so users who toggled the indicator off in a newer build keep it off.
        defaults.set(ActivationIndicatorMode.hidden.rawValue, forKey: "cotabbySelectedIndicatorMode")
        defaults.set(true, forKey: "cotabbyShowCaretIndicator")

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        XCTAssertFalse(data.showIndicator)
    }

    func test_load_fallsBackToLegacyBoolWhenModeAbsent() async {
        let defaults = makeIsolatedDefaults()
        defaults.set(false, forKey: "cotabbyShowCaretIndicator")

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        XCTAssertFalse(data.showIndicator)
    }

    func test_load_writesBothIndicatorKeysBack() async {
        let defaults = makeIsolatedDefaults()

        _ = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        // The write-back keeps the legacy bool in sync with the mode so an older build reading the
        // legacy key still sees the right value.
        XCTAssertNotNil(defaults.string(forKey: "cotabbySelectedIndicatorMode"))
        XCTAssertNotNil(defaults.object(forKey: "cotabbyShowCaretIndicator"))
    }

    // MARK: - Debounce / focus-poll capping

    func test_load_capsPersistedDebounceAtShippedDefault() async {
        let defaults = makeIsolatedDefaults()
        defaults.set(999, forKey: "cotabbyDebounceMilliseconds")

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        // A stale high value (a previous default) must be capped so the latency improvement reaches
        // existing installs.
        XCTAssertEqual(data.debounceMilliseconds, SuggestionConfiguration.standard.debounceMilliseconds)
    }

    func test_load_capsPersistedFocusPollAtShippedDefault() async {
        let defaults = makeIsolatedDefaults()
        defaults.set(999, forKey: "cotabbyFocusPollIntervalMilliseconds")

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        XCTAssertEqual(
            data.focusPollIntervalMilliseconds,
            SuggestionConfiguration.standard.focusPollIntervalMilliseconds
        )
    }

    // MARK: - Keybinding defaults

    func test_load_acceptanceKeyModifiersAbsentDefaultsToEmpty() async {
        let defaults = makeIsolatedDefaults()

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        // Absence means a pre-modifier-support install: the bare-key binding must keep working.
        XCTAssertTrue(data.acceptanceKeyModifiers.isEmpty)
        XCTAssertEqual(data.acceptanceKeyCode, SuggestionSettingsStore.defaultAcceptanceKeyCode)
    }

    func test_load_globalToggleAbsentDefaultsToDisabledSentinel() async {
        let defaults = makeIsolatedDefaults()

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        // The global-toggle hotkey is opt-in; an absent entry must NOT bind a real key.
        XCTAssertEqual(data.globalToggleKeyCode, SuggestionSettingsStore.disabledKeyCode)
        XCTAssertEqual(data.globalToggleKeyLabel, SuggestionSettingsStore.disabledKeyLabel)
    }

    // MARK: - Custom rules: absent seeds defaults, present is honored

    func test_load_customRulesAbsentSeedsBaseline() async {
        let defaults = makeIsolatedDefaults()

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        XCTAssertEqual(data.customRules, CustomRulesCatalog.defaultRules)
    }

    func test_load_customRulesPresentHonoredVerbatim() async {
        let defaults = makeIsolatedDefaults()
        defaults.set(["Write in the user's voice"], forKey: "cotabbyCustomRules")

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        XCTAssertEqual(data.customRules, CustomRulesCatalog.normalize(["Write in the user's voice"]))
    }

    // MARK: - Legacy custom-indicator PNG scrub

    func test_load_scrubsLegacyCustomIndicatorImageData() async {
        let defaults = makeIsolatedDefaults()
        defaults.set(Data([0x1, 0x2, 0x3]), forKey: "cotabbyCustomIndicatorImageData")

        _ = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        XCTAssertNil(defaults.data(forKey: "cotabbyCustomIndicatorImageData"))
    }

    // MARK: - Save / load round-trips

    func test_load_automaticTypoFixingDefaultsOff() async {
        let defaults = makeIsolatedDefaults()

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        XCTAssertFalse(data.automaticallyFixTypos)
    }

    func test_saveThenLoad_roundTripsScalarFields() async {
        let defaults = makeIsolatedDefaults()
        let store = SuggestionSettingsStore(userDefaults: defaults)

        store.saveGloballyEnabled(false)
        store.saveUserName("Ada Lovelace")
        store.saveGhostTextOpacity(0.5)
        store.saveGhostTextSizeMultiplier(0.8)
        store.saveFastModeEnabled(true)
        store.saveAutomaticallyFixTypos(true)
        store.saveMenuBarWordCountVisible(false)

        let data = store.load(configuration: .standard)

        XCTAssertFalse(data.isGloballyEnabled)
        XCTAssertEqual(data.userName, "Ada Lovelace")
        XCTAssertEqual(data.ghostTextOpacity, 0.5, accuracy: 0.0001)
        XCTAssertEqual(data.ghostTextSizeMultiplier, 0.8, accuracy: 0.0001)
        XCTAssertTrue(data.isFastModeEnabled)
        XCTAssertTrue(data.automaticallyFixTypos)
        XCTAssertFalse(data.isMenuBarWordCountVisible)
    }

    func test_saveThenLoad_roundTripsAcceptanceKey() async {
        let defaults = makeIsolatedDefaults()
        let store = SuggestionSettingsStore(userDefaults: defaults)

        store.saveAcceptanceKey(keyCode: 36, modifiers: [], label: "Return")

        let data = store.load(configuration: .standard)

        XCTAssertEqual(data.acceptanceKeyCode, 36)
        XCTAssertEqual(data.acceptanceKeyLabel, "Return")
        XCTAssertTrue(data.acceptanceKeyModifiers.isEmpty)
    }

    func test_load_clampsOutOfRangeGhostTextOpacity() async {
        let defaults = makeIsolatedDefaults()
        // Below the floor: must clamp up rather than render the suggestion invisible.
        defaults.set(0.01, forKey: "cotabbyGhostTextOpacity")

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        XCTAssertEqual(data.ghostTextOpacity, SuggestionSettingsStore.minimumGhostTextOpacity, accuracy: 0.0001)
    }

    // MARK: - Ghost text size multiplier

    func test_load_defaultsGhostTextSizeMultiplierWhenUnset() async {
        let defaults = makeIsolatedDefaults()

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        XCTAssertEqual(
            data.ghostTextSizeMultiplier,
            SuggestionSettingsStore.defaultGhostTextSizeMultiplier,
            accuracy: 0.0001
        )
    }

    func test_load_clampsOutOfRangeGhostTextSizeMultiplier() async {
        let defaults = makeIsolatedDefaults()
        // Above the ceiling: must clamp down so a hand-edited default can't render giant ghost text.
        defaults.set(5.0, forKey: "cotabbyGhostTextSizeMultiplier")

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        XCTAssertEqual(
            data.ghostTextSizeMultiplier,
            SuggestionSettingsStore.maximumGhostTextSizeMultiplier,
            accuracy: 0.0001
        )
    }

    // MARK: - Spelling dictionaries

    func test_load_spellingDictionariesAbsentDefaultsToEnglish() async {
        let defaults = makeIsolatedDefaults()

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        XCTAssertEqual(
            data.enabledSpellingDictionaryCodes,
            SpellingDictionaryCatalog.defaultEnabledCodes
        )
    }

    func test_load_spellingDictionariesFiltersUnknownCodesAndStabilizesOrder() async {
        let defaults = makeIsolatedDefaults()
        defaults.set([" ru ", "unknown", "de", "ru"], forKey: "cotabbyEnabledSpellingDictionaryCodes")

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        XCTAssertEqual(data.enabledSpellingDictionaryCodes, ["de", "ru"])
        XCTAssertEqual(
            defaults.stringArray(forKey: "cotabbyEnabledSpellingDictionaryCodes"),
            ["de", "ru"]
        )
    }

    func test_load_spellingDictionariesPreservesExplicitEmptySelection() async {
        let defaults = makeIsolatedDefaults()
        defaults.set([String](), forKey: "cotabbyEnabledSpellingDictionaryCodes")

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        XCTAssertTrue(data.enabledSpellingDictionaryCodes.isEmpty)
    }

    // MARK: - Power-based switching profiles

    func test_load_powerProfileEnginesDefaultToOpenSourceWhenAbsent() async {
        let defaults = makeIsolatedDefaults()

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        // A fresh install has no per-power-source engine stored: both default to Open Source so the
        // pre-engine behavior (local model switching only) is preserved.
        XCTAssertEqual(data.batteryEngine, .llamaOpenSource)
        XCTAssertEqual(data.pluggedInEngine, .llamaOpenSource)
    }

    func test_saveThenLoad_roundTripsPowerProfileEngines() async {
        let defaults = makeIsolatedDefaults()
        let store = SuggestionSettingsStore(userDefaults: defaults)

        store.saveBatteryEngine(.appleIntelligence)
        store.savePluggedInEngine(.llamaOpenSource)
        store.savePluggedInModelFilename("big-model.gguf")

        let data = store.load(configuration: .standard)

        XCTAssertEqual(data.batteryEngine, .appleIntelligence)
        XCTAssertEqual(data.pluggedInEngine, .llamaOpenSource)
        XCTAssertEqual(data.pluggedInModelFilename, "big-model.gguf")
    }

    func test_load_legacyModelOnlyProfilePreservedWithOpenSourceEngine() async {
        let defaults = makeIsolatedDefaults()
        // A user upgrading from the model-only release has filenames but no engine keys. The model
        // selections must survive and the engine must resolve to Open Source so their setup is intact.
        defaults.set("small-model.gguf", forKey: "cotabbyBatteryModelFilename")
        defaults.set("big-model.gguf", forKey: "cotabbyPluggedInModelFilename")

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        XCTAssertEqual(data.batteryEngine, .llamaOpenSource)
        XCTAssertEqual(data.batteryModelFilename, "small-model.gguf")
        XCTAssertEqual(data.pluggedInEngine, .llamaOpenSource)
        XCTAssertEqual(data.pluggedInModelFilename, "big-model.gguf")
    }

    // MARK: - Custom suggestion text color

    func test_load_normalizesPersistedColorHexAndWritesItBack() async {
        let defaults = makeIsolatedDefaults()
        // Hand-written value: leading #, lowercase, stray whitespace. The store must canonicalize it
        // so the overlay and the picker agree on one representation.
        defaults.set("  #a1b2c3 ", forKey: "cotabbyCustomSuggestionTextColorHex")

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        XCTAssertEqual(data.customSuggestionTextColorHex, "A1B2C3")
        XCTAssertEqual(defaults.string(forKey: "cotabbyCustomSuggestionTextColorHex"), "A1B2C3")
    }

    func test_load_discardsMalformedColorHex() async {
        let defaults = makeIsolatedDefaults()
        defaults.set("ZZZZZZ", forKey: "cotabbyCustomSuggestionTextColorHex")

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        XCTAssertNil(data.customSuggestionTextColorHex)
        // The write-back must scrub the unusable value rather than re-persisting it.
        XCTAssertNil(defaults.string(forKey: "cotabbyCustomSuggestionTextColorHex"))
    }

    func test_saveCustomSuggestionTextColorHex_persistsValueAndNilRemoves() async {
        let defaults = makeIsolatedDefaults()
        let store = SuggestionSettingsStore(userDefaults: defaults)

        store.saveCustomSuggestionTextColorHex("AABBCC")
        XCTAssertEqual(defaults.string(forKey: "cotabbyCustomSuggestionTextColorHex"), "AABBCC")

        store.saveCustomSuggestionTextColorHex(nil)
        XCTAssertNil(defaults.object(forKey: "cotabbyCustomSuggestionTextColorHex"))
    }

    func test_normalizedHexString_acceptsOnlySixHexDigits() async {
        XCTAssertNil(SuggestionSettingsStore.normalizedHexString(nil))
        XCTAssertEqual(SuggestionSettingsStore.normalizedHexString("#ffcc00"), "FFCC00")
        XCTAssertEqual(SuggestionSettingsStore.normalizedHexString(" 0011fF "), "0011FF")
        XCTAssertNil(SuggestionSettingsStore.normalizedHexString("FFF"), "Three-digit shorthand is not supported")
        XCTAssertNil(SuggestionSettingsStore.normalizedHexString("A1B2C3D"), "Seven digits is not a color")
        XCTAssertNil(SuggestionSettingsStore.normalizedHexString("GGGGGG"), "Non-hex characters must be rejected")
    }

    // MARK: - Clamp guards for non-finite values

    func test_clampedGhostTextOpacity_nonFiniteFallsBackToDefault() async {
        XCTAssertEqual(
            SuggestionSettingsStore.clampedGhostTextOpacity(.nan),
            SuggestionSettingsStore.defaultGhostTextOpacity
        )
        XCTAssertEqual(
            SuggestionSettingsStore.clampedGhostTextOpacity(.infinity),
            SuggestionSettingsStore.defaultGhostTextOpacity
        )
    }

    func test_clampedGhostTextSizeMultiplier_nonFiniteFallsBackToDefault() async {
        XCTAssertEqual(
            SuggestionSettingsStore.clampedGhostTextSizeMultiplier(.nan),
            SuggestionSettingsStore.defaultGhostTextSizeMultiplier
        )
        XCTAssertEqual(
            SuggestionSettingsStore.clampedGhostTextSizeMultiplier(-.infinity),
            SuggestionSettingsStore.defaultGhostTextSizeMultiplier
        )
    }

    // MARK: - Disabled-app rule sanitization

    func test_load_dropsDisabledAppRulesWithBlankBundleIdentifiers() async throws {
        let defaults = makeIsolatedDefaults()
        // A rule without a bundle identifier can never match a focused app, so it must be dropped
        // on load instead of lingering as an unmatchable ghost row in Settings.
        let persisted = [
            DisabledApplicationRule(bundleIdentifier: "   ", displayName: "Ghost"),
            DisabledApplicationRule(bundleIdentifier: " com.example.keep ", displayName: "  ")
        ]
        defaults.set(try JSONEncoder().encode(persisted), forKey: "cotabbyDisabledAppRules")

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        XCTAssertEqual(data.disabledAppRules.map(\.bundleIdentifier), ["com.example.keep"])
        // A blank display name falls back to the bundle identifier so the row is never unlabeled.
        XCTAssertEqual(data.disabledAppRules.first?.displayName, "com.example.keep")
    }

    func test_sortedDisabledAppRules_tieBreaksEqualNamesByBundleIdentifier() async {
        let sorted = SuggestionSettingsStore.sortedDisabledAppRules([
            DisabledApplicationRule(bundleIdentifier: "com.z.notes", displayName: "Notes"),
            DisabledApplicationRule(bundleIdentifier: "com.a.notes", displayName: "notes")
        ])

        // Case-insensitively equal display names must order deterministically by identifier.
        XCTAssertEqual(sorted.map(\.bundleIdentifier), ["com.a.notes", "com.z.notes"])
    }

    func test_normalizedBundleIdentifier_nilAndBlankCollapseToNil() async {
        XCTAssertNil(SuggestionSettingsStore.normalizedBundleIdentifier(nil))
        XCTAssertNil(SuggestionSettingsStore.normalizedBundleIdentifier("   "))
        XCTAssertEqual(SuggestionSettingsStore.normalizedBundleIdentifier(" com.example.app "), "com.example.app")
    }

    // MARK: - Corrupt persisted types degrade gracefully

    func test_load_recoversFromWrongValueTypesInDefaults() async {
        let defaults = makeIsolatedDefaults()
        // A hand-edited or corrupted plist can hold the wrong type under our keys. Load must treat
        // each one as "present but unusable" and degrade to a safe value instead of crashing.
        // Data is used for the user name because UserDefaults converts numbers to strings.
        defaults.set(Data([0x01]), forKey: "cotabbyUserName")
        defaults.set("not-an-array", forKey: "cotabbyCustomRules")
        defaults.set("not-an-array", forKey: "cotabbyResponseLanguages")
        defaults.set("not-an-array", forKey: "cotabbyEnabledSpellingDictionaryCodes")

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        XCTAssertEqual(data.userName, "")
        XCTAssertEqual(data.customRules, [])
        XCTAssertEqual(data.responseLanguages, [])
        XCTAssertEqual(data.enabledSpellingDictionaryCodes, [])
    }

    // MARK: - Reset to defaults

    func test_resetToDefaults_clearsAllKeysAndReloadsDefaults() async {
        // Baseline: defaults resolved from a clean suite.
        let pristine = SuggestionSettingsStore(userDefaults: makeIsolatedDefaults())
            .load(configuration: .standard)

        let defaults = makeIsolatedDefaults()
        let store = SuggestionSettingsStore(userDefaults: defaults)

        // Dirty every persisted field with a genuine non-default (correct types, through the same save
        // methods the facade uses), plus the legacy single-language key. If `resetToDefaults` misses
        // any key, the reloaded data stays != pristine and the Equatable check below fails loudly.
        store.saveGloballyEnabled(false)
        store.saveDisabledAppRules(
            [DisabledApplicationRule(bundleIdentifier: "com.example.app", displayName: "Example")]
        )
        store.saveSuggestInIntegratedTerminals(true)
        store.saveShowIndicator(false)
        store.saveShowAcceptanceHint(false)
        store.saveCustomSuggestionTextColorHex("A1B2C3")
        store.saveGhostTextOpacity(0.4)
        store.saveGhostTextSizeMultiplier(1.2)
        store.saveSelectedEngine(.appleIntelligence)
        store.saveSelectedWordCountPreset(.fourToSeven)
        store.saveUsingCustomWordCountRange(true)
        store.saveCustomWordCountRange(low: 3, high: 9)
        store.saveClipboardContextEnabled(true)
        store.saveSurfaceContextEnabled(false)
        store.saveFastModeEnabled(true)
        store.saveSuppressCompletionsOnTypo(false)
        store.saveOfferTypoCorrections(false)
        store.saveEnabledSpellingDictionaryCodes([])
        store.saveAutomaticallyFixTypos(true)
        store.savePerformanceTrackingEnabled(true)
        store.saveMenuBarWordCountVisible(false)
        store.saveMirrorPreference(.alwaysMirror)
        store.saveUserName("Ada")
        store.saveCustomRules(["Be terse"])
        store.saveExtendedContext("glossary")
        store.saveResponseLanguages([])
        store.saveDebounceMilliseconds(15)
        store.saveFocusPollIntervalMilliseconds(30)
        store.saveMultiLineEnabled(true)
        store.saveEmojiPickerEnabled(false)
        store.saveMacroExpansionEnabled(false)
        store.savePreferredEmojiSkinTone(.mediumDark)
        store.savePreferredEmojiGender(.female)
        store.saveAutoAcceptTrailingPunctuation(false)
        store.saveAddSpaceAfterAccept(true)
        store.saveStreamSuggestionsWhileGenerating(true)
        store.saveAcceptanceKey(keyCode: 36, modifiers: [], label: "Return")
        store.saveFullAcceptanceKey(keyCode: 49, modifiers: [], label: "Space")
        store.saveGlobalToggleKey(keyCode: 47, modifiers: [], label: ".")
        store.saveAcceptanceGranularity(.phrase)
        store.savePowerBasedModelSwitchingEnabled(true)
        store.saveBatteryEngine(.appleIntelligence)
        store.saveBatteryModelFilename("small.gguf")
        store.savePluggedInEngine(.appleIntelligence)
        store.savePluggedInModelFilename("big.gguf")
        defaults.set("Spanish", forKey: "cotabbyResponseLanguage")

        // Sanity: the dirty values really landed, so the assertions below aren't vacuous.
        XCTAssertNotEqual(store.load(configuration: .standard), pristine)

        let afterReset = store.resetToDefaults(configuration: .standard)

        XCTAssertEqual(afterReset, pristine)
        XCTAssertEqual(store.load(configuration: .standard), pristine, "reset must persist for the next launch")
        XCTAssertNil(defaults.object(forKey: "cotabbyResponseLanguage"), "the legacy key must be scrubbed too")
    }

    // MARK: - helpers

    /// Each store test gets its own isolated UserDefaults so state cannot leak between cases.
    /// `removePersistentDomain` resets the in-memory suite to a clean slate before use, and the
    /// teardown block removes whatever the test persisted so suites do not accumulate on disk.
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "cotabby.test.settingsStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
