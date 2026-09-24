import XCTest
@testable import Cotabby

/// Locks down the duplicate-shortcut guard that keeps the three keybindings unambiguous.
///
/// The original bug: the global-toggle hotkey was excluded from any conflict check, so a user could
/// bind it to a key already used by an accept binding (the default full-accept key is backtick). The
/// head-inserted accept tap then consumed the shared key before the toggle tap saw it, so Toggle
/// Tabby silently did nothing. `conflictingShortcutName` is the single source of truth the recorder
/// consults to refuse such a binding up front.
@MainActor
final class ShortcutConflictTests: XCTestCase {

    /// A combo already owned by another action is reported, keyed by that action's display name.
    func test_conflict_reportsActionOwningTheCombo() {
        let model = makeModel()
        // Default full-accept is backtick (keyCode 50). Binding the toggle to the same key must
        // be flagged as a conflict with "Accept Entire Suggestion".
        let conflict = model.conflictingShortcutName(
            keyCode: 50,
            modifiers: [],
            excluding: .toggleTabby
        )
        XCTAssertEqual(conflict, "Accept Entire Suggestion")
    }

    /// An action never conflicts with itself, so re-recording the same key for the same binding is
    /// allowed (e.g. confirming the current value).
    func test_conflict_excludesTheActionBeingEdited() {
        let model = makeModel()
        let conflict = model.conflictingShortcutName(
            keyCode: model.acceptanceKeyCode,
            modifiers: model.acceptanceKeyModifiers,
            excluding: .acceptWord
        )
        XCTAssertNil(conflict)
    }

    /// A free combo (default Accept Word is Tab; some other key is unused) reports no conflict.
    func test_conflict_allowsUnusedCombo() {
        let model = makeModel()
        // keyCode 49 is Space, unused by any default binding.
        let conflict = model.conflictingShortcutName(
            keyCode: 49,
            modifiers: [],
            excluding: .toggleTabby
        )
        XCTAssertNil(conflict)
    }

    /// The disabled sentinel never conflicts: multiple actions may be left unbound at once.
    func test_conflict_ignoresDisabledSentinel() {
        let model = makeModel()
        let conflict = model.conflictingShortcutName(
            keyCode: SuggestionSettingsModel.disabledKeyCode,
            modifiers: [],
            excluding: .toggleTabby
        )
        XCTAssertNil(conflict)
    }

    /// Same key but different modifiers is a distinct binding and must not be flagged.
    func test_conflict_treatsModifierSetsAsDistinct() {
        let model = makeModel()
        // Full-accept default is bare backtick; backtick + shift is a different binding.
        let conflict = model.conflictingShortcutName(
            keyCode: 50,
            modifiers: [.shift],
            excluding: .toggleTabby
        )
        XCTAssertNil(conflict)
    }

    // MARK: - Per-app override scoping

    func test_perAppConflict_allowsSameComboAcrossDifferentApps() {
        let model = makeModel()
        model.setPerAppAcceptKey(
            bundleIdentifier: "com.apple.notes", displayName: "Notes",
            keyCode: 49, modifiers: [], label: "Space"
        )

        let conflict = model.conflictingPerAppShortcutName(
            forBundleIdentifier: "com.apple.terminal",
            keyCode: 49,
            modifiers: [],
            excluding: .acceptWord
        )
        XCTAssertNil(conflict)
    }

    func test_perAppConflict_flagsSameAppCrossActionCollision() {
        let model = makeModel()
        model.setPerAppFullAcceptKey(
            bundleIdentifier: "com.apple.notes", displayName: "Notes",
            keyCode: 49, modifiers: [], label: "Space"
        )

        let conflict = model.conflictingPerAppShortcutName(
            forBundleIdentifier: "com.apple.notes",
            keyCode: 49,
            modifiers: [],
            excluding: .acceptWord
        )
        XCTAssertEqual(conflict, "Accept Entire Suggestion")
    }

    func test_perAppConflict_flagsGlobalFullAcceptFallbackCollision() {
        let model = makeModel()

        let conflict = model.conflictingPerAppShortcutName(
            forBundleIdentifier: "com.apple.notes",
            keyCode: model.fullAcceptanceKeyCode,
            modifiers: model.fullAcceptanceKeyModifiers,
            excluding: .acceptWord
        )

        XCTAssertEqual(conflict, "Accept Entire Suggestion")
    }

    func test_perAppConflict_flagsGlobalAcceptFallbackCollision() {
        let model = makeModel()

        let conflict = model.conflictingPerAppShortcutName(
            forBundleIdentifier: "com.apple.notes",
            keyCode: model.acceptanceKeyCode,
            modifiers: model.acceptanceKeyModifiers,
            excluding: .acceptEntireSuggestion
        )

        XCTAssertEqual(conflict, "Accept Word")
    }

    func test_perAppConflict_flagsGlobalToggleCollision() {
        let model = makeModel()
        model.setGlobalToggleKey(keyCode: 49, modifiers: [.command, .shift], label: "⌘⇧Space")
        let conflict = model.conflictingPerAppShortcutName(
            forBundleIdentifier: "com.apple.notes",
            keyCode: 49,
            modifiers: [.command, .shift],
            excluding: .acceptWord
        )
        XCTAssertEqual(conflict, "Toggle CoHamster")
    }

    func test_perAppConflict_allowsRebindingSameActionToSameKey() {
        let model = makeModel()
        model.setPerAppAcceptKey(
            bundleIdentifier: "com.apple.notes", displayName: "Notes",
            keyCode: 49, modifiers: [], label: "Space"
        )
        let conflict = model.conflictingPerAppShortcutName(
            forBundleIdentifier: "com.apple.notes",
            keyCode: 49,
            modifiers: [],
            excluding: .acceptWord
        )
        XCTAssertNil(conflict)
    }

    // MARK: - Helpers

    private func makeModel() -> SuggestionSettingsModel {
        let suiteName = "cotabby.test.shortcutConflict.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
    }
}
