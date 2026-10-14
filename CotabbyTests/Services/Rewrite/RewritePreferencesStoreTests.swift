import XCTest
@testable import Cotabby

/// The Rewrite settings persist under their own keys and start from safe defaults: the local
/// provider, so nothing leaves the Mac until the user picks a cloud service.
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
        let store = RewritePreferencesStore(userDefaults: defaults)
        Self.retained.append(store)
        return store
    }

    func test_defaultsAreLocal() {
        let prefs = makeStore().preferences
        XCTAssertTrue(prefs.isEnabled)
        XCTAssertEqual(prefs.provider, .local)
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
}
