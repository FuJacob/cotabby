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

    func test_saveThenLoad_roundTripsScalarFields() async {
        let defaults = makeIsolatedDefaults()
        let store = SuggestionSettingsStore(userDefaults: defaults)

        store.saveGloballyEnabled(false)
        store.saveUserName("Ada Lovelace")
        store.saveGhostTextOpacity(0.5)
        store.saveGhostTextSizeMultiplier(0.8)
        store.saveFastModeEnabled(true)
        store.saveMenuBarWordCountVisible(false)

        let data = store.load(configuration: .standard)

        XCTAssertFalse(data.isGloballyEnabled)
        XCTAssertEqual(data.userName, "Ada Lovelace")
        XCTAssertEqual(data.ghostTextOpacity, 0.5, accuracy: 0.0001)
        XCTAssertEqual(data.ghostTextSizeMultiplier, 0.8, accuracy: 0.0001)
        XCTAssertTrue(data.isFastModeEnabled)
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

    // MARK: - helpers

    /// Each store test gets its own isolated UserDefaults so state cannot leak between cases.
    /// `removePersistentDomain` resets the in-memory suite to a clean slate before use.
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "cotabby.test.settingsStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
