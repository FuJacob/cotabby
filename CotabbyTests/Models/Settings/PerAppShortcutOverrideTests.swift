import XCTest
@testable import Cotabby

/// Pins the persisted JSON shape of per-app shortcut overrides (`cotabbyPerAppShortcutOverrides`)
/// and which overrides take an app off the global Accept Entire Suggestion binding. The store's
/// round-trip tests prove save and load agree with each other; decoding a literal here additionally
/// proves an existing user's stored rows keep decoding after a property rename.
final class PerAppShortcutOverrideTests: XCTestCase {
    func test_decodesStoredRowWithScalarModifiersAndMissingActionsAsInherited() throws {
        let json = Data(#"""
        [{
            "bundleIdentifier": "com.apple.Notes",
            "displayName": "Notes",
            "acceptance": {"keyCode": 49, "modifiers": 2, "label": "⇧Space"}
        }]
        """#.utf8)

        let overrides = try JSONDecoder().decode([PerAppShortcutOverride].self, from: json)
        let override = try XCTUnwrap(overrides.first)

        XCTAssertEqual(override.id, "com.apple.Notes")
        XCTAssertEqual(override.displayName, "Notes")
        XCTAssertEqual(
            override.acceptance,
            SuggestionShortcutBindingSettings(keyCode: 49, modifiers: .shift, label: "⇧Space")
        )
        // An absent action means "inherit the global binding", not "disabled".
        XCTAssertNil(override.fullAcceptance)
    }

    /// Apps in this set stop following the global Accept Entire Suggestion binding, including the
    /// double tap. Disabling the action for an app is a choice too, so only an unset slot inherits;
    /// a per-app Accept Word key alone must leave the global full-accept binding in force.
    func test_bundleIdentifiersOverridingFullAcceptance_countsARecordedKeyAndDisableButNotInherit() {
        let recorded = SuggestionShortcutBindingSettings(keyCode: 36, modifiers: .command, label: "⌘↩")
        let overrides = [
            PerAppShortcutOverride(bundleIdentifier: "com.example.recorded", displayName: "Recorded",
                                   acceptance: nil, fullAcceptance: recorded),
            PerAppShortcutOverride(bundleIdentifier: "com.example.disabled", displayName: "Disabled",
                                   acceptance: nil, fullAcceptance: .unbound),
            PerAppShortcutOverride(bundleIdentifier: "com.example.wordOnly", displayName: "Word only",
                                   acceptance: recorded, fullAcceptance: nil),
            PerAppShortcutOverride(bundleIdentifier: "com.example.tracked", displayName: "Tracked",
                                   acceptance: nil, fullAcceptance: nil)
        ]

        XCTAssertEqual(
            PerAppShortcutOverride.bundleIdentifiersOverridingFullAcceptance(in: overrides),
            ["com.example.recorded", "com.example.disabled"]
        )
        XCTAssertEqual(PerAppShortcutOverride.bundleIdentifiersOverridingFullAcceptance(in: []), [])
    }
}
