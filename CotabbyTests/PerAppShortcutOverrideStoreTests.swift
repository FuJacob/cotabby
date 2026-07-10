import XCTest
@testable import Cotabby

/// Locks down the load/sanitize/persist round-trip for the per-app shortcut overrides store.
///
/// The store has to be as forgiving as `disabledAppRules`: a fresh install has an absent key
/// (not an empty array); a mutated-back-to-empty store removes the key entirely; whitespace
/// and duplicate bundle ids are normalized on read. These properties matter because the model
/// publishes the array to the InputMonitor's event-time closures — any decode quirk that
/// resurrects a zombie row would resolve to the wrong key on every keystroke.
@MainActor
final class PerAppShortcutOverrideStoreTests: XCTestCase {

    func test_freshInstall_hasNoOverrides() {
        let model = makeModel()
        XCTAssertTrue(model.perAppShortcutOverrides.isEmpty)
    }

    func test_setPerAppAcceptKey_persistsAndRoundTrips() {
        let suiteName = makeSuiteName()
        let firstModel = makeModel(suiteName: suiteName)
        firstModel.setPerAppAcceptKey(
            bundleIdentifier: "com.apple.notes",
            displayName: "Notes",
            keyCode: 49,
            modifiers: [.shift],
            label: "⇧Space"
        )

        let secondModel = makeModel(suiteName: suiteName)
        XCTAssertEqual(secondModel.perAppShortcutOverrides.count, 1)
        let restored = try? XCTUnwrap(secondModel.perAppShortcutOverrides.first)
        XCTAssertEqual(restored?.bundleIdentifier, "com.apple.notes")
        XCTAssertEqual(restored?.acceptKeyCode, 49)
        XCTAssertEqual(restored?.acceptKeyModifiers, [.shift])
        XCTAssertEqual(restored?.acceptKeyLabel, "⇧Space")
        // The full-accept fields were never set on this app, so they must round-trip as nil so
        // the resolver inherits the global binding.
        XCTAssertNil(restored?.fullAcceptKeyCode)
        XCTAssertNil(restored?.fullAcceptKeyModifiers)
        XCTAssertNil(restored?.fullAcceptKeyLabel)
    }

    /// Clearing both halves of an override must drop the row entirely so the resolver re-inherits
    /// the global on this app. Leaving an empty row would publish a no-op that survives across
    /// launches and burns lookup time forever.
    func test_clearingBothActions_removesRowEntirely() {
        let model = makeModel()
        model.setPerAppAcceptKey(
            bundleIdentifier: "com.apple.notes", displayName: "Notes",
            keyCode: 49, modifiers: [], label: "Space"
        )
        model.setPerAppFullAcceptKey(
            bundleIdentifier: "com.apple.notes", displayName: "Notes",
            keyCode: 36, modifiers: [.command], label: "⌘Return"
        )
        XCTAssertEqual(model.perAppShortcutOverrides.count, 1)

        model.clearPerAppAcceptKey(bundleIdentifier: "com.apple.notes")
        XCTAssertEqual(model.perAppShortcutOverrides.count, 1, "Row still has full-accept.")

        model.clearPerAppFullAcceptKey(bundleIdentifier: "com.apple.notes")
        XCTAssertTrue(
            model.perAppShortcutOverrides.isEmpty,
            "Both actions cleared → row is gone and resolver inherits the global."
        )
    }

    /// `removePerAppOverride` is the user's "Reset to global" affordance: it drops the row no
    /// matter what bindings it held.
    func test_removePerAppOverride_dropsRowImmediately() {
        let model = makeModel()
        model.setPerAppAcceptKey(
            bundleIdentifier: "com.apple.notes", displayName: "Notes",
            keyCode: 49, modifiers: [], label: "Space"
        )
        model.removePerAppOverride(bundleIdentifier: "com.apple.notes")
        XCTAssertTrue(model.perAppShortcutOverrides.isEmpty)
    }

    /// Bundle identifiers with surrounding whitespace must be normalized; otherwise the same
    /// app can end up with two rows after a typo-y manual edit of UserDefaults.
    func test_setPerAppAcceptKey_normalizesBundleIdentifier() {
        let model = makeModel()
        model.setPerAppAcceptKey(
            bundleIdentifier: "  com.apple.notes  ",
            displayName: "Notes",
            keyCode: 49, modifiers: [], label: "Space"
        )
        XCTAssertEqual(model.perAppShortcutOverrides.first?.bundleIdentifier, "com.apple.notes")
    }

    /// Empty/whitespace bundle ids are rejected outright — a row with no identity could never be
    /// resolved.
    func test_setPerAppAcceptKey_rejectsEmptyBundleIdentifier() {
        let model = makeModel()
        model.setPerAppAcceptKey(
            bundleIdentifier: "   ",
            displayName: "Whatever",
            keyCode: 49, modifiers: [], label: "Space"
        )
        XCTAssertTrue(model.perAppShortcutOverrides.isEmpty)
    }

    /// Two writes for the same bundle identifier replace each other rather than producing two
    /// rows. Without this property the published array could grow unboundedly across a long
    /// session of re-recording the same app.
    func test_setPerAppAcceptKey_dedupesByBundleIdentifier() {
        let model = makeModel()
        model.setPerAppAcceptKey(
            bundleIdentifier: "com.apple.notes", displayName: "Notes",
            keyCode: 49, modifiers: [], label: "Space"
        )
        model.setPerAppAcceptKey(
            bundleIdentifier: "com.apple.notes", displayName: "Notes",
            keyCode: 36, modifiers: [.command], label: "⌘Return"
        )
        XCTAssertEqual(model.perAppShortcutOverrides.count, 1)
        XCTAssertEqual(model.perAppShortcutOverrides.first?.acceptKeyCode, 36)
    }

    /// A previously-persisted empty row (e.g. a corrupted/hand-edited UserDefault) is dropped on
    /// read so the live store never carries a no-op forward.
    func test_sanitize_dropsEmptyRowsOnLoad() throws {
        let suiteName = makeSuiteName()
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // Encode a row with all-nil bindings (which the live store never produces) and stash it
        // directly to simulate a previous-version persisted blob.
        let empty = PerAppShortcutOverride(
            bundleIdentifier: "com.apple.notes",
            displayName: "Notes",
            acceptKeyCode: nil, acceptKeyModifiers: nil, acceptKeyLabel: nil,
            fullAcceptKeyCode: nil, fullAcceptKeyModifiers: nil, fullAcceptKeyLabel: nil
        )
        let data = try JSONEncoder().encode([empty])
        defaults.set(data, forKey: "cotabbyPerAppShortcutOverrides")

        let model = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        XCTAssertTrue(
            model.perAppShortcutOverrides.isEmpty,
            "Empty row must be sanitized away so it doesn't waste resolver lookups."
        )
    }

    /// A row persisted with a *partial* binding — a key code but no modifiers/label, which
    /// `ShortcutResolver` would silently ignore — is collapsed to "inherit global" on load so it can't
    /// show in Settings as a phantom that never fires. The well-formed full-accept binding on the same
    /// row is preserved.
    func test_sanitize_collapsesPartialBindingOnLoad() throws {
        let suiteName = makeSuiteName()
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let partial = PerAppShortcutOverride(
            bundleIdentifier: "com.apple.notes",
            displayName: "Notes",
            acceptKeyCode: 49, acceptKeyModifiers: nil, acceptKeyLabel: nil,
            fullAcceptKeyCode: 36, fullAcceptKeyModifiers: [.command], fullAcceptKeyLabel: "⌘Return"
        )
        let data = try JSONEncoder().encode([partial])
        defaults.set(data, forKey: "cotabbyPerAppShortcutOverrides")

        let model = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        let restored = try XCTUnwrap(model.perAppShortcutOverrides.first)
        // The partial accept binding collapses to inherit-global...
        XCTAssertNil(restored.acceptKeyCode)
        XCTAssertNil(restored.acceptKeyModifiers)
        XCTAssertNil(restored.acceptKeyLabel)
        // ...while the well-formed full-accept binding is preserved.
        XCTAssertEqual(restored.fullAcceptKeyCode, 36)
        XCTAssertEqual(restored.fullAcceptKeyModifiers, [.command])
        XCTAssertEqual(restored.fullAcceptKeyLabel, "⌘Return")
    }

    // MARK: - Helpers

    private func makeSuiteName() -> String {
        "cotabby.test.perAppOverride.\(UUID().uuidString)"
    }

    private func makeModel(suiteName: String? = nil) -> SuggestionSettingsModel {
        let name = suiteName ?? makeSuiteName()
        let defaults = UserDefaults(suiteName: name)!
        // Don't blow away the suite when an explicit suiteName was passed — that's the cross-launch
        // test using two model instances against the same defaults.
        if suiteName == nil {
            defaults.removePersistentDomain(forName: name)
        }
        return SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
    }
}
