import XCTest
@testable import Cotabby

/// Pins the persisted JSON shape of per-app shortcut overrides (`cotabbyPerAppShortcutOverrides`).
/// The store's round-trip tests prove save and load agree with each other; decoding a literal here
/// additionally proves an existing user's stored rows keep decoding after a property rename.
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
}
