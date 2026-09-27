import XCTest
@testable import Cotabby

/// Verifies that domain grouping is an in-memory ownership change, not a persistence migration.
/// Existing flat accessors remain part of the compatibility seam while new code reads cohesive
/// general, engine, completion, context, correction, presentation, inline-feature, and shortcut values.
@MainActor
final class SuggestionSettingsDomainTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "cotabby.test.settingsDomains.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func test_storeLoad_groupsExistingPersistenceKeysByOwningDomain() {
        defaults.set(false, forKey: "cotabbyGloballyEnabled")
        defaults.set(SuggestionEngineKind.appleIntelligence.rawValue, forKey: "cotabbySelectedEngine")
        defaults.set(true, forKey: "cotabbyClipboardContextEnabled")
        defaults.set(false, forKey: "cotabbyShowAcceptanceHint")
        defaults.set(false, forKey: "cotabbyLowPowerModeAutoDisableEnabled")
        defaults.set(false, forKey: "cotabbySuggestWithinWords")
        defaults.set(false, forKey: "cotabbyShowFollowingWords")

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        XCTAssertFalse(data.general.isGloballyEnabled)
        XCTAssertEqual(data.engine.selectedEngine, .appleIntelligence)
        XCTAssertTrue(data.context.isClipboardContextEnabled)
        XCTAssertFalse(data.presentation.showAcceptanceHint)
        XCTAssertFalse(data.general.isLowPowerModeAutoDisableEnabled)
        XCTAssertFalse(data.completion.suggestWithinWords)
        XCTAssertFalse(data.completion.showFollowingWords)
        XCTAssertEqual(data.shortcuts.acceptance.keyCode, SuggestionSettingsStore.defaultAcceptanceKeyCode)
    }

    func test_flatCompatibilityAccessors_andDomainValuesStayBidirectionallyConsistent() {
        var data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        data.openAICompatibleModelName = "forwarded-model"
        data.completion.acceptanceGranularity = .phrase
        data.suggestWithinWords = false
        data.showFollowingWords = false
        data.ghostTextOpacity = 0.7
        data.shortcuts.globalToggle.label = "⌥G"

        XCTAssertEqual(data.engine.openAICompatibleModelName, "forwarded-model")
        XCTAssertEqual(data.acceptanceGranularity, .phrase)
        XCTAssertFalse(data.completion.suggestWithinWords)
        XCTAssertFalse(data.completion.showFollowingWords)
        data.completion.suggestWithinWords = true
        XCTAssertTrue(data.suggestWithinWords)
        data.completion.showFollowingWords = true
        XCTAssertTrue(data.showFollowingWords)
        XCTAssertEqual(data.presentation.ghostTextOpacity, 0.7)
        XCTAssertEqual(data.globalToggleKeyLabel, "⌥G")
    }

    /// The flat forwarding accessors are hand-written pairs, so a copy-paste slip (battery writing
    /// the plugged-in slot, floor writing the ceiling) would compile. Distinct values for each
    /// look-alike pair make any cross-wiring visible.
    func test_flatAccessors_routeLookAlikeFieldsToTheirOwnDomainSlot() {
        var data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        data.batteryEngine = .appleIntelligence
        data.pluggedInEngine = .openAICompatible
        data.batteryModelFilename = "battery.gguf"
        data.pluggedInModelFilename = "plugged.gguf"
        data.batteryEndpointModelName = "battery-endpoint"
        data.pluggedInEndpointModelName = "plugged-endpoint"
        data.ghostFontSizeFloor = 12
        data.ghostFontSizeCeiling = 40
        data.customWordCountLowWords = 3
        data.customWordCountHighWords = 9
        data.acceptanceKeyCode = 1
        data.fullAcceptanceKeyCode = 2
        data.globalToggleKeyCode = 3
        data.acceptanceKeyModifiers = [.command]
        data.fullAcceptanceKeyModifiers = [.shift]
        data.globalToggleKeyModifiers = [.option]
        data.suppressCompletionsOnTypo = true
        data.offerTypoCorrections = false
        data.isClipboardContextEnabled = true
        data.isSurfaceContextEnabled = false

        XCTAssertEqual(data.engine.batteryEngine, .appleIntelligence)
        XCTAssertEqual(data.engine.pluggedInEngine, .openAICompatible)
        XCTAssertEqual(data.engine.batteryModelFilename, "battery.gguf")
        XCTAssertEqual(data.engine.pluggedInModelFilename, "plugged.gguf")
        XCTAssertEqual(data.engine.batteryEndpointModelName, "battery-endpoint")
        XCTAssertEqual(data.engine.pluggedInEndpointModelName, "plugged-endpoint")
        XCTAssertEqual(data.presentation.ghostFontSizeFloor, 12)
        XCTAssertEqual(data.presentation.ghostFontSizeCeiling, 40)
        XCTAssertEqual(data.completion.customWordCountLowWords, 3)
        XCTAssertEqual(data.completion.customWordCountHighWords, 9)
        XCTAssertEqual(data.shortcuts.acceptance.keyCode, 1)
        XCTAssertEqual(data.shortcuts.fullAcceptance.keyCode, 2)
        XCTAssertEqual(data.shortcuts.globalToggle.keyCode, 3)
        XCTAssertEqual(data.shortcuts.acceptance.modifiers, [.command])
        XCTAssertEqual(data.shortcuts.fullAcceptance.modifiers, [.shift])
        XCTAssertEqual(data.shortcuts.globalToggle.modifiers, [.option])
        XCTAssertTrue(data.correction.suppressCompletionsOnTypo)
        XCTAssertFalse(data.correction.offerTypoCorrections)
        XCTAssertTrue(data.context.isClipboardContextEnabled)
        XCTAssertFalse(data.context.isSurfaceContextEnabled)
    }

    func test_modelDomainProjection_preservesFlatPropertiesAndGenerationSnapshot() {
        let model = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        model.selectEngine(.openAICompatible)
        model.setOpenAICompatibleModelName("domain-model")
        model.setFastModeEnabled(true)
        model.setOfferTypoCorrections(false)
        model.setAcceptanceGranularity(.phrase)
        model.setShowFollowingWords(false)

        let domains = model.domainSettings

        XCTAssertEqual(domains.engine.selectedEngine, model.selectedEngine)
        XCTAssertEqual(domains.engine.openAICompatibleModelName, "domain-model")
        XCTAssertTrue(domains.context.isFastModeEnabled)
        XCTAssertFalse(domains.correction.offerTypoCorrections)
        XCTAssertEqual(domains.completion.acceptanceGranularity, model.snapshot.acceptanceGranularity)
        XCTAssertEqual(model.snapshot.selectedEngine, .openAICompatible)
        XCTAssertFalse(domains.completion.showFollowingWords)
        XCTAssertFalse(model.snapshot.showFollowingWords)
    }
}
