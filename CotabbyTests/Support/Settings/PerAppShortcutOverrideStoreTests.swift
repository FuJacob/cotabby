import XCTest
@testable import Cotabby

/// Covers persistence and identity sanitization for per-app shortcut overrides.
@MainActor
final class PerAppShortcutOverrideStoreTests: XCTestCase {
    func test_freshInstall_hasNoOverrides() {
        XCTAssertTrue(makeModel().perAppShortcutOverrides.isEmpty)
    }

    func test_addPerAppShortcutApp_persistsInheritedBindings() throws {
        let defaults = makeIsolatedDefaults()
        makeModel(defaults).addPerAppShortcutApp(
            bundleIdentifier: "com.apple.notes",
            displayName: "Notes"
        )

        let restored = try XCTUnwrap(makeModel(defaults).perAppShortcutOverrides.first)
        XCTAssertEqual(restored.bundleIdentifier, "com.apple.notes")
        XCTAssertNil(restored.acceptance)
        XCTAssertNil(restored.fullAcceptance)
    }

    func test_setPerAppAcceptKey_roundTripsAtomicBinding() throws {
        let defaults = makeIsolatedDefaults()
        makeModel(defaults).setPerAppAcceptKey(
            bundleIdentifier: "com.apple.notes",
            displayName: "Notes",
            keyCode: 49,
            modifiers: [.shift],
            label: "⇧Space"
        )

        let restored = try XCTUnwrap(makeModel(defaults).perAppShortcutOverrides.first)
        XCTAssertEqual(
            restored.acceptance,
            .init(keyCode: 49, modifiers: [.shift], label: "⇧Space")
        )
        XCTAssertNil(restored.fullAcceptance)
    }

    func test_clearingBothActions_keepsTrackedAppWithInheritedBindings() throws {
        let model = makeModel()
        setNotesSpaceAcceptKey(on: model)
        model.setPerAppFullAcceptKey(
            bundleIdentifier: "com.apple.notes",
            displayName: "Notes",
            keyCode: 36,
            modifiers: [.command],
            label: "⌘Return"
        )

        model.clearPerAppAcceptKey(bundleIdentifier: "com.apple.notes")
        model.clearPerAppFullAcceptKey(bundleIdentifier: "com.apple.notes")

        let restored = try XCTUnwrap(model.perAppShortcutOverrides.first)
        XCTAssertNil(restored.acceptance)
        XCTAssertNil(restored.fullAcceptance)
    }

    func test_removePerAppOverride_dropsRow() {
        let model = makeModel()
        setNotesSpaceAcceptKey(on: model)

        model.removePerAppOverride(bundleIdentifier: "com.apple.notes")

        XCTAssertTrue(model.perAppShortcutOverrides.isEmpty)
    }

    func test_setPerAppAcceptKey_normalizesBundleIdentifier() {
        let model = makeModel()
        model.setPerAppAcceptKey(
            bundleIdentifier: "  com.apple.notes  ",
            displayName: "Notes",
            keyCode: 49,
            modifiers: [],
            label: "Space"
        )

        XCTAssertEqual(model.perAppShortcutOverrides.first?.bundleIdentifier, "com.apple.notes")
    }

    func test_setPerAppAcceptKey_rejectsEmptyBundleIdentifier() {
        let model = makeModel()
        model.setPerAppAcceptKey(
            bundleIdentifier: "   ",
            displayName: "Whatever",
            keyCode: 49,
            modifiers: [],
            label: "Space"
        )

        XCTAssertTrue(model.perAppShortcutOverrides.isEmpty)
    }

    func test_setPerAppAcceptKey_replacesExistingBundle() {
        let model = makeModel()
        setNotesSpaceAcceptKey(on: model)
        model.setPerAppAcceptKey(
            bundleIdentifier: "com.apple.notes",
            displayName: "Notes",
            keyCode: 36,
            modifiers: [.command],
            label: "⌘Return"
        )

        XCTAssertEqual(model.perAppShortcutOverrides.count, 1)
        XCTAssertEqual(
            model.perAppShortcutOverrides.first?.acceptance,
            .init(keyCode: 36, modifiers: [.command], label: "⌘Return")
        )
    }

    func test_load_normalizesAndDeduplicatesBundleIdentifiers() throws {
        let defaults = makeIsolatedDefaults()
        let staleRows = [
            PerAppShortcutOverride(
                bundleIdentifier: " com.apple.notes ",
                displayName: "Old Name",
                acceptance: .init(keyCode: 49, modifiers: [], label: "Space")
            ),
            PerAppShortcutOverride(
                bundleIdentifier: "com.apple.notes",
                displayName: "Notes",
                fullAcceptance: .init(keyCode: 36, modifiers: [.command], label: "⌘Return")
            )
        ]
        defaults.set(
            try JSONEncoder().encode(staleRows),
            forKey: "cotabbyPerAppShortcutOverrides"
        )

        let model = makeModel(defaults)
        let restored = try XCTUnwrap(model.perAppShortcutOverrides.first)
        XCTAssertEqual(model.perAppShortcutOverrides.count, 1)
        XCTAssertEqual(restored.bundleIdentifier, "com.apple.notes")
        XCTAssertEqual(restored.displayName, "Notes")
        XCTAssertNil(restored.acceptance)
        XCTAssertEqual(
            restored.fullAcceptance,
            .init(keyCode: 36, modifiers: [.command], label: "⌘Return")
        )
    }

    /// The common starting point: Notes tracked with a plain Space accept binding.
    private func setNotesSpaceAcceptKey(on model: SuggestionSettingsModel) {
        model.setPerAppAcceptKey(
            bundleIdentifier: "com.apple.notes",
            displayName: "Notes",
            keyCode: 49,
            modifiers: [],
            label: "Space"
        )
    }

    private func makeModel(_ defaults: UserDefaults? = nil) -> SuggestionSettingsModel {
        SuggestionSettingsModel(
            configuration: .standard,
            userDefaults: defaults ?? makeIsolatedDefaults()
        )
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "cotabby.test.perAppOverride.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
