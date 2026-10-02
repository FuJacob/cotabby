import XCTest
@testable import Cotabby

final class WindowFeatureScopeTests: XCTestCase {
    func test_windowKeyCombinesBundleAndNormalizedTitle() {
        XCTAssertEqual(
            WindowFeatureScope.windowKey(bundleIdentifier: "com.microsoft.teams2", windowTitle: "  Chat |  Simeon  "),
            "com.microsoft.teams2\u{1F}Chat | Simeon"
        )
    }

    func test_unreadBadgeDoesNotMakeANewWindow() {
        let plain = WindowFeatureScope.windowKey(bundleIdentifier: "net.whatsapp.WhatsApp", windowTitle: "WhatsApp")
        XCTAssertEqual(WindowFeatureScope.windowKey(bundleIdentifier: "net.whatsapp.WhatsApp", windowTitle: "(3) WhatsApp"), plain)
        XCTAssertEqual(WindowFeatureScope.windowKey(bundleIdentifier: "net.whatsapp.WhatsApp", windowTitle: "(99+) WhatsApp"), plain)
    }

    func test_noKeyWithoutBundleOrTitle() {
        XCTAssertNil(WindowFeatureScope.windowKey(bundleIdentifier: nil, windowTitle: "Chat"))
        XCTAssertNil(WindowFeatureScope.windowKey(bundleIdentifier: "com.apple.TextEdit", windowTitle: "   "))
        XCTAssertNil(WindowFeatureScope.windowKey(bundleIdentifier: "com.apple.TextEdit", windowTitle: nil))
    }

    func test_longTitlesAreBounded() {
        let title = String(repeating: "a", count: 1_000)
        XCTAssertEqual(WindowFeatureScope.normalizedTitle(title)?.count, WindowFeatureScope.maximumTitleCharacters)
    }

    func test_windowChoiceWinsOverApp() {
        XCTAssertTrue(WindowFeatureScope.resolve(appEnabled: false, windowOverride: true))
        XCTAssertFalse(WindowFeatureScope.resolve(appEnabled: true, windowOverride: false))
        XCTAssertTrue(WindowFeatureScope.resolve(appEnabled: true, windowOverride: nil))
    }

    func test_effectiveDisabledAppsFollowsWindowChoice() {
        let disabled: Set<String> = ["com.other"]
        XCTAssertEqual(
            WindowFeatureScope.effectiveDisabledApps(disabled, bundleIdentifier: "com.app", windowOverride: false),
            ["com.other", "com.app"]
        )
        XCTAssertEqual(
            WindowFeatureScope.effectiveDisabledApps(["com.app"], bundleIdentifier: "com.app", windowOverride: true),
            []
        )
        XCTAssertEqual(
            WindowFeatureScope.effectiveDisabledApps(disabled, bundleIdentifier: "com.app", windowOverride: nil),
            disabled
        )
    }
}

@MainActor
final class WindowFeatureOverrideStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "WindowFeatureOverrideStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func test_setClearAndPersist() {
        let store = WindowFeatureOverrideStore(userDefaults: defaults)
        store.setOverride(false, for: .autocomplete, windowKey: "app\u{1F}A")
        store.setOverride(true, for: .translation, windowKey: "app\u{1F}A")
        XCTAssertEqual(store.override(for: .autocomplete, windowKey: "app\u{1F}A"), false)
        XCTAssertTrue(store.hasEnabledWindow(for: .translation, bundleIdentifier: "app"))
        XCTAssertFalse(store.hasEnabledWindow(for: .translation, bundleIdentifier: "ap"))

        let reloaded = WindowFeatureOverrideStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.override(for: .autocomplete, windowKey: "app\u{1F}A"), false)
        XCTAssertEqual(reloaded.override(for: .translation, windowKey: "app\u{1F}A"), true)

        reloaded.setOverride(nil, for: .autocomplete, windowKey: "app\u{1F}A")
        XCTAssertNil(WindowFeatureOverrideStore(userDefaults: defaults).override(for: .autocomplete, windowKey: "app\u{1F}A"))
    }

    func test_oldestWindowsAreTrimmed() {
        let store = WindowFeatureOverrideStore(userDefaults: defaults)
        for index in 0...WindowFeatureOverrideStore.maximumWindowsPerFeature {
            store.setOverride(true, for: .autocomplete, windowKey: "w\(index)")
        }
        XCTAssertNil(store.override(for: .autocomplete, windowKey: "w0"))
        XCTAssertEqual(store.override(for: .autocomplete, windowKey: "w1"), true)
        XCTAssertEqual(store.overrides[.autocomplete]?.count, WindowFeatureOverrideStore.maximumWindowsPerFeature)
    }
}
