import XCTest
@testable import Cotabby

/// The Rewrite settings persist under their own keys and start on "Same as autocomplete", and an
/// earlier "local" choice migrates only on a definitive Apple Intelligence answer.
@MainActor
final class RewritePreferencesStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private static var retained: [AnyObject] = []

    override func setUp() {
        super.setUp()
        suiteName = "RewritePreferencesStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> RewritePreferencesStore {
        let store = RewritePreferencesStore(userDefaults: defaults, appleIntelligence: nil)
        Self.retained.append(store)
        return store
    }

    func test_defaultsFollowAutocomplete() {
        let prefs = makeStore().preferences
        XCTAssertTrue(prefs.isEnabled)
        XCTAssertEqual(prefs.provider, .sameAsAutocomplete)
        XCTAssertTrue(prefs.showsButtonOnSelection)
        XCTAssertEqual(prefs.shortcutKeyCode, 15)
        XCTAssertEqual(prefs.shortcutModifiers, ShortcutModifierMask.control.rawValue | ShortcutModifierMask.option.rawValue)
    }

    func test_changesPersistAcrossInstances() {
        let store = makeStore()
        store.setProvider(.api)
        store.setCloudProvider(.custom)
        store.setAPIBaseURL("https://api.openai.com/v1")
        store.setAPIModelName("gpt-4.1-mini")
        store.setShowsButtonOnSelection(false)
        store.setEnabled(false)

        let reloaded = makeStore().preferences
        XCTAssertEqual(reloaded.provider, .api)
        XCTAssertEqual(reloaded.apiBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(reloaded.cloudProvider, .custom)
        XCTAssertEqual(reloaded.apiModelName, "gpt-4.1-mini")
        XCTAssertFalse(reloaded.showsButtonOnSelection)
        XCTAssertFalse(reloaded.isEnabled)
    }

    func test_actionsAndTonesInPopupOrder() {
        XCTAssertEqual(RewriteAction.tones.map(\.label), ["Family", "Friendly", "Close friend", "Formal", "Customer"])
        XCTAssertEqual(RewriteAction.refinements.map(\.label), ["Shorter", "Longer"])
        XCTAssertEqual(RewriteAction.custom("make it warmer").label, "Custom")
    }

    func test_fixTickBoxDefaultsOnAndPersists() {
        let store = makeStore()
        XCTAssertTrue(store.preferences.fixesMistakes)
        store.setFixesMistakes(false)
        XCTAssertFalse(makeStore().preferences.fixesMistakes)
    }

    // MARK: - Cloud providers

    func test_newInstallsStartOnClaude() {
        XCTAssertEqual(makeStore().preferences.cloudProvider, .anthropic)
        XCTAssertEqual(makeStore().preferences.apiModelName, "claude-opus-5-5")
    }

    func test_eachProviderRemembersItsOwnModel() {
        let store = makeStore()
        store.setCloudProvider(.anthropic)
        store.setAPIModelName("claude-haiku-5-5")
        store.setCloudProvider(.openAI)
        store.setAPIModelName("some-openai-model")
        store.setCloudProvider(.anthropic)
        XCTAssertEqual(store.preferences.apiModelName, "claude-haiku-5-5")
        let reloaded = makeStore().preferences
        XCTAssertEqual(reloaded.cloudProvider, .anthropic)
        XCTAssertEqual(reloaded.apiModelName, "claude-haiku-5-5")
    }

    func test_providerCatalog() {
        XCTAssertEqual(RewriteCloudProvider.anthropic.baseURL, "https://api.anthropic.com/v1")
        XCTAssertEqual(RewriteCloudProvider.openAI.baseURL, "https://api.openai.com/v1")
        XCTAssertEqual(RewriteCloudProvider.gemini.baseURL, "https://generativelanguage.googleapis.com/v1beta/openai")
        XCTAssertNil(RewriteCloudProvider.custom.baseURL)
        XCTAssertEqual(RewriteCloudProvider.openAI.keychainSuffix, "rewrite-endpoint.openAI")
        XCTAssertEqual(RewriteCloudProvider.custom.keychainSuffix, "rewrite-endpoint.custom")
        XCTAssertEqual(Set(RewriteCloudProvider.allCases.map(\.keychainSuffix)).count, RewriteCloudProvider.allCases.count,
                       "every service keeps its own key")
        XCTAssertTrue(RewriteCloudProvider.anthropic.suggestedModels.contains("claude-sonnet-5-5"))
    }

    /// A model list (or its error) loaded for one service or URL is not shown after the user moved on.
    func test_modelListBelongsOnlyToTheServiceAndURLItWasLoadedFor() {
        var prefs = RewritePreferences.defaults
        prefs.cloudProvider = .openAI
        XCTAssertTrue(prefs.isModelListSource(service: .openAI, baseURL: "https://api.openai.com/v1"))
        XCTAssertFalse(prefs.isModelListSource(service: .anthropic, baseURL: "https://api.openai.com/v1"))
        prefs.cloudProvider = .custom
        prefs.apiBaseURL = "http://gateway.example.com/v1"
        XCTAssertTrue(prefs.isModelListSource(service: .custom, baseURL: "http://gateway.example.com/v1"))
        XCTAssertFalse(prefs.isModelListSource(service: .custom, baseURL: "http://other.example.com/v1"))
    }

    // MARK: - Provider choice and migration

    func test_providerChoicePersists() {
        let store = makeStore()
        store.setProvider(.localEndpoint)
        XCTAssertEqual(makeStore().preferences.provider, .localEndpoint)
        XCTAssertEqual(defaults.string(forKey: "cotabbyRewriteProvider"), "localEndpoint")
    }

    func test_storedLocalMigratesToAppleIntelligenceWhenAvailable() {
        defaults.set("local", forKey: "cotabbyRewriteProvider")
        let store = RewritePreferencesStore(userDefaults: defaults, isAppleSilicon: true, appleIntelligence: .available)
        XCTAssertEqual(store.preferences.provider, .appleIntelligence)
        XCTAssertEqual(defaults.string(forKey: "cotabbyRewriteProvider"), "appleIntelligence", "migrated once, then stable")
    }

    func test_storedLocalMigratesToOpenSourceWhenAppleIntelligenceIsPermanentlyUnavailable() {
        defaults.set("local", forKey: "cotabbyRewriteProvider")
        let state = FoundationModelAvailabilityState.unavailable("Not eligible.", permanent: true)
        let store = RewritePreferencesStore(userDefaults: defaults, isAppleSilicon: true, appleIntelligence: state)
        XCTAssertEqual(store.preferences.provider, .openSource)
        XCTAssertEqual(defaults.string(forKey: "cotabbyRewriteProvider"), "openSource")
    }

    func test_aTransientStateKeepsLocalStoredAndRunsOpenSourceForNow() {
        defaults.set("local", forKey: "cotabbyRewriteProvider")
        for state in [FoundationModelAvailabilityState?.none, .unavailable("Still downloading."), .unavailable("Turned off.")] {
            let store = RewritePreferencesStore(userDefaults: defaults, isAppleSilicon: true, appleIntelligence: state)
            XCTAssertEqual(store.preferences.provider, .openSource)
            XCTAssertEqual(defaults.string(forKey: "cotabbyRewriteProvider"), "local", "not persisted on a transient answer")
        }
    }

    func test_aLaterAvailableAnswerFinishesTheMigration() {
        defaults.set("local", forKey: "cotabbyRewriteProvider")
        let store = RewritePreferencesStore(userDefaults: defaults, isAppleSilicon: true,
                                            appleIntelligence: .unavailable("Still downloading."))
        store.noteAppleIntelligence(.unavailable("Still downloading."))
        XCTAssertEqual(defaults.string(forKey: "cotabbyRewriteProvider"), "local")
        store.noteAppleIntelligence(.available)
        XCTAssertEqual(store.preferences.provider, .appleIntelligence)
        XCTAssertEqual(defaults.string(forKey: "cotabbyRewriteProvider"), "appleIntelligence")
    }

    func test_aLaterPermanentAnswerMigratesToOpenSource() {
        defaults.set("local", forKey: "cotabbyRewriteProvider")
        let store = RewritePreferencesStore(userDefaults: defaults, isAppleSilicon: true, appleIntelligence: nil)
        store.noteAppleIntelligence(.unavailable("Not eligible.", permanent: true))
        XCTAssertEqual(defaults.string(forKey: "cotabbyRewriteProvider"), "openSource")
    }

    func test_aChoiceMadeMeanwhileIsNeverOverwrittenByAnAvailabilityAnswer() {
        defaults.set("local", forKey: "cotabbyRewriteProvider")
        let store = RewritePreferencesStore(userDefaults: defaults, isAppleSilicon: true, appleIntelligence: nil)
        store.setProvider(.api)
        store.noteAppleIntelligence(.available)
        XCTAssertEqual(store.preferences.provider, .api)
    }

    func test_storedAPIAndMLXAreKept() {
        defaults.set("api", forKey: "cotabbyRewriteProvider")
        XCTAssertEqual(RewritePreferencesStore(userDefaults: defaults, isAppleSilicon: true, appleIntelligence: nil).preferences.provider, .api)
        defaults.set("mlx", forKey: "cotabbyRewriteProvider")
        XCTAssertEqual(RewritePreferencesStore(userDefaults: defaults, isAppleSilicon: true, appleIntelligence: nil).preferences.provider, .mlx)
    }

    func test_storedMLXFallsBackToOpenSourceWithoutAppleSilicon() {
        defaults.set("mlx", forKey: "cotabbyRewriteProvider")
        let store = RewritePreferencesStore(userDefaults: defaults, isAppleSilicon: false, appleIntelligence: nil)
        XCTAssertEqual(store.preferences.provider, .openSource)
    }
}
