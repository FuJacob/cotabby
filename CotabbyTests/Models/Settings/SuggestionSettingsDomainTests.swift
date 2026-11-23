import XCTest
@testable import Cotabby

/// Verifies that domain grouping is an in-memory ownership change, not a persistence migration:
/// the existing flat UserDefaults keys load into the general, engine, completion, context,
/// correction, presentation, inline-feature, and shortcut values that own them.
@MainActor
final class SuggestionSettingsDomainTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = IsolatedUserDefaults.make()
    }

    override func tearDown() {
        defaults = nil
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
