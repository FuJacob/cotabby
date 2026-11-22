import CoreGraphics
import XCTest
@testable import Cotabby

/// Locks the "one slot, one shortcut" rule for Accept Entire Suggestion: it is either a one-press
/// key or a double press of Accept Word, never both, and the display helpers views read agree with
/// whichever one is stored.
@MainActor
final class SuggestionSettingsModelDoubleTapTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "cotabby.test.settingsModelDoubleTap.\(UUID().uuidString)"
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

    func test_defaultSlotHoldsTheFactoryOnePressKey() {
        let model = makeModel()

        XCTAssertFalse(model.isDoubleTapFullAcceptanceActive)
        XCTAssertTrue(model.isFullAcceptanceShortcutDefault)
        XCTAssertEqual(model.fullAcceptanceDisplayLabel, SuggestionSettingsModel.defaultFullAcceptanceKeyLabel)
        XCTAssertFalse(model.snapshot.doubleTapAcceptsEntireSuggestion)
    }

    func test_recordingDoubleTapReplacesTheOnePressKeyAndPersists() {
        let model = makeModel()

        model.setDoubleTapFullAcceptance()

        XCTAssertTrue(model.isDoubleTapFullAcceptanceActive)
        XCTAssertEqual(model.fullAcceptanceKeyCode, SuggestionSettingsModel.disabledKeyCode)
        XCTAssertEqual(model.fullAcceptanceDisplayLabel, "Tab Tab")
        XCTAssertTrue(model.hasFullAcceptanceShortcut)
        XCTAssertFalse(model.isFullAcceptanceShortcutDefault)
        XCTAssertTrue(model.snapshot.doubleTapAcceptsEntireSuggestion)

        let reloaded = makeModel()
        XCTAssertTrue(reloaded.isDoubleTapFullAcceptanceActive)
        XCTAssertEqual(reloaded.fullAcceptanceKeyCode, SuggestionSettingsModel.disabledKeyCode)
    }

    func test_recordingAOnePressKeyReplacesTheDoubleTap() {
        let model = makeModel()
        model.setDoubleTapFullAcceptance()

        model.setFullAcceptanceKey(keyCode: 48, modifiers: [.option], label: "⌥ Tab")

        XCTAssertFalse(model.isDoubleTapFullAcceptanceActive)
        XCTAssertEqual(model.fullAcceptanceDisplayLabel, "⌥ Tab")
        XCTAssertFalse(makeModel().doubleTapAcceptsEntireSuggestion)
    }

    func test_resetReturnsToTheFactoryKey() {
        let model = makeModel()
        model.setDoubleTapFullAcceptance()

        model.setFullAcceptanceKey(
            keyCode: SuggestionSettingsModel.defaultFullAcceptanceKeyCode,
            modifiers: [],
            label: SuggestionSettingsModel.defaultFullAcceptanceKeyLabel
        )

        XCTAssertTrue(model.isFullAcceptanceShortcutDefault)
        XCTAssertFalse(model.isDoubleTapFullAcceptanceActive)
    }

    func test_clearRemovesTheDoubleTapToo() {
        let model = makeModel()
        model.setDoubleTapFullAcceptance()

        model.clearFullAcceptanceKey()

        XCTAssertFalse(model.hasFullAcceptanceShortcut)
        XCTAssertFalse(model.doubleTapAcceptsEntireSuggestion)
        XCTAssertEqual(model.fullAcceptanceDisplayLabel, SuggestionSettingsModel.disabledKeyLabel)
    }

    func test_doubleTapCannotBeBoundWithoutAnAcceptWordKey() {
        let model = makeModel()
        model.clearAcceptanceKey()

        model.setDoubleTapFullAcceptance()

        XCTAssertFalse(model.doubleTapAcceptsEntireSuggestion)
        XCTAssertTrue(model.isFullAcceptanceShortcutDefault, "The one-press key must survive the refused bind")
    }

    func test_clearingAcceptWordAlsoRemovesTheDoubleTap() {
        let model = makeModel()
        model.setDoubleTapFullAcceptance()

        model.clearAcceptanceKey()

        XCTAssertFalse(model.doubleTapAcceptsEntireSuggestion)
        XCTAssertFalse(model.hasFullAcceptanceShortcut)
    }

    func test_doubleTapLabelFollowsTheAcceptWordKey() {
        let model = makeModel()
        model.setDoubleTapFullAcceptance()

        model.setAcceptanceKey(keyCode: 36, modifiers: [], label: "Return")

        XCTAssertEqual(model.fullAcceptanceDisplayLabel, "Return Return")
    }

    func test_inheritedLabelUsesTheAppsOwnAcceptWordKey() {
        let model = makeModel()
        model.setDoubleTapFullAcceptance()
        model.setPerAppAcceptKey(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal",
                                 keyCode: 36, modifiers: [], label: "Return")

        XCTAssertEqual(model.inheritedFullAcceptanceDisplayLabel(forBundleIdentifier: "com.apple.mail"), "Tab Tab")
        XCTAssertEqual(model.inheritedFullAcceptanceDisplayLabel(forBundleIdentifier: "com.apple.Terminal"), "Return Return")
    }

    func test_inheritedLabelHasNoDoubleTapWhereAcceptWordIsDisabled() {
        let model = makeModel()
        model.setDoubleTapFullAcceptance()
        model.setPerAppAcceptKey(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal",
                                 keyCode: SuggestionSettingsModel.disabledKeyCode, modifiers: [], label: "None")

        XCTAssertEqual(model.inheritedFullAcceptanceDisplayLabel(forBundleIdentifier: "com.apple.Terminal"),
                       SuggestionSettingsModel.disabledKeyLabel)
    }

    func test_appsWithTheirOwnFullAcceptBindingKeepItOverTheDoubleTap() {
        let model = makeModel()
        model.setDoubleTapFullAcceptance()
        // Disable is an explicit per-app binding too: "no key accepts everything here".
        model.setPerAppFullAcceptKey(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal",
                                     keyCode: SuggestionSettingsModel.disabledKeyCode, modifiers: [], label: "None")
        model.setPerAppAcceptKey(bundleIdentifier: "com.apple.mail", displayName: "Mail",
                                 keyCode: 36, modifiers: [], label: "Return")

        let snapshot = model.snapshot
        XCTAssertFalse(snapshot.isDoubleTapFullAcceptanceActive(forBundleIdentifier: "com.apple.Terminal"))
        // Overriding only Accept Word keeps the inherited slot; the double tap moves to that key.
        XCTAssertTrue(snapshot.isDoubleTapFullAcceptanceActive(forBundleIdentifier: "com.apple.mail"))
        XCTAssertTrue(snapshot.isDoubleTapFullAcceptanceActive(forBundleIdentifier: "com.apple.TextEdit"))
        XCTAssertTrue(snapshot.isDoubleTapFullAcceptanceActive(forBundleIdentifier: nil))

        model.clearPerAppFullAcceptKey(bundleIdentifier: "com.apple.Terminal")
        XCTAssertTrue(model.snapshot.isDoubleTapFullAcceptanceActive(forBundleIdentifier: "com.apple.Terminal"))
    }
}
