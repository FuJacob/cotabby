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

        let data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        XCTAssertFalse(data.general.isGloballyEnabled)
        XCTAssertEqual(data.engine.selectedEngine, .appleIntelligence)
        XCTAssertTrue(data.context.isClipboardContextEnabled)
        XCTAssertFalse(data.presentation.showAcceptanceHint)
        XCTAssertEqual(data.shortcuts.acceptance.keyCode, SuggestionSettingsStore.defaultAcceptanceKeyCode)
    }

    func test_flatCompatibilityAccessors_andDomainValuesStayBidirectionallyConsistent() {
        var data = SuggestionSettingsStore(userDefaults: defaults).load(configuration: .standard)

        data.openAICompatibleModelName = "forwarded-model"
        data.completion.acceptanceGranularity = .phrase
        data.ghostTextOpacity = 0.7
        data.shortcuts.globalToggle.label = "⌥G"

        XCTAssertEqual(data.engine.openAICompatibleModelName, "forwarded-model")
        XCTAssertEqual(data.acceptanceGranularity, .phrase)
        XCTAssertEqual(data.presentation.ghostTextOpacity, 0.7)
        XCTAssertEqual(data.globalToggleKeyLabel, "⌥G")
    }

    func test_modelDomainProjection_preservesFlatPropertiesAndGenerationSnapshot() {
        let model = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        model.selectEngine(.openAICompatible)
        model.setOpenAICompatibleModelName("domain-model")
        model.setFastModeEnabled(true)
        model.setOfferTypoCorrections(false)
        model.setAcceptanceGranularity(.phrase)

        let domains = model.domainSettings

        XCTAssertEqual(domains.engine.selectedEngine, model.selectedEngine)
        XCTAssertEqual(domains.engine.openAICompatibleModelName, "domain-model")
        XCTAssertTrue(domains.context.isFastModeEnabled)
        XCTAssertFalse(domains.correction.offerTypoCorrections)
        XCTAssertEqual(domains.completion.acceptanceGranularity, model.snapshot.acceptanceGranularity)
        XCTAssertEqual(model.snapshot.selectedEngine, .openAICompatible)
    }
}
