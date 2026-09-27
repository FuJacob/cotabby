import ApplicationServices
import XCTest
@testable import Cotabby

/// Locks the human-readable shortcut labels rendered in the settings keycap and the ghost-text
/// hint pill. These strings are user-facing UI contracts, so each mapping is asserted exactly.
final class KeyCodeLabelsTests: XCTestCase {
    // MARK: - Special key names

    func test_label_mapsEverySpecialKeyByKeyCode() {
        let cases: [(keyCode: CGKeyCode, label: String)] = [
            (48, "Tab"), (49, "Space"), (51, "Delete"), (53, "Escape"),
            (117, "Forward Delete"), (36, "Return"), (76, "Enter"),
            (123, "Left Arrow"), (124, "Right Arrow"), (125, "Down Arrow"), (126, "Up Arrow"),
            (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"),
            (96, "F5"), (97, "F6"), (98, "F7"), (100, "F8"),
            (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12")
        ]
        for testCase in cases {
            XCTAssertEqual(KeyCodeLabels.label(for: testCase.keyCode, fallback: nil), testCase.label, "key \(testCase.keyCode)")
        }
    }

    func test_label_prefersSpecialNameOverFallbackCharacters() {
        // Tab must never render as a literal tab character even if the event carried one.
        XCTAssertEqual(KeyCodeLabels.label(for: 48, fallback: "\t"), "Tab")
        XCTAssertEqual(KeyCodeLabels.label(for: 49, fallback: " "), "Space")
        XCTAssertEqual(KeyCodeLabels.label(for: 36, fallback: "x"), "Return")
    }

    // MARK: - Fallback characters

    func test_label_uppercasesAndTrimsFallbackCharacters() {
        XCTAssertEqual(KeyCodeLabels.label(for: 0, fallback: "a"), "A")
        XCTAssertEqual(KeyCodeLabels.label(for: 6, fallback: " z "), "Z")
        XCTAssertEqual(KeyCodeLabels.label(for: 18, fallback: "1"), "1")
        XCTAssertEqual(KeyCodeLabels.label(for: 0, fallback: "\nab\n"), "AB")
    }

    func test_label_usefulFallbackBeatsPhysicalKeyDescription() {
        // On a layout where the ISO key does produce a glyph, show the glyph, not the position.
        XCTAssertEqual(KeyCodeLabels.label(for: 10, fallback: "§"), "§")
        XCTAssertEqual(KeyCodeLabels.label(for: 50, fallback: "`"), "`")
    }

    func test_label_describesPhysicalKeysWhenFallbackIsUnhelpful() {
        // ISO/JIS layout keys that produce no glyph: the fallback is empty or whitespace, so the
        // user gets a positional description instead of a blank keycap.
        XCTAssertEqual(KeyCodeLabels.label(for: 10, fallback: ""), "Key above Tab")
        XCTAssertEqual(KeyCodeLabels.label(for: 50, fallback: "   "), "Key above Tab")
        XCTAssertEqual(KeyCodeLabels.label(for: 93, fallback: nil), "Key beside Right Shift")
    }

    func test_label_fallsBackToNumericDescriptionForUnknownKeys() {
        XCTAssertEqual(KeyCodeLabels.label(for: 7, fallback: nil), "Key 7")
        XCTAssertEqual(KeyCodeLabels.label(for: 7, fallback: " \n"), "Key 7")
        XCTAssertEqual(KeyCodeLabels.label(for: CGKeyCode.max, fallback: nil), "Key 65535")
    }

    // MARK: - Modifier glyphs

    func test_modifierGlyphs_followMacOSConventionOrdering() {
        // Control, Option, Shift, Command: the order macOS renders in menus, regardless of the
        // order the caller assembled the mask in.
        XCTAssertEqual(KeyCodeLabels.modifierGlyphs([]), "")
        XCTAssertEqual(KeyCodeLabels.modifierGlyphs([.command]), "⌘")
        XCTAssertEqual(KeyCodeLabels.modifierGlyphs([.control]), "⌃")
        XCTAssertEqual(KeyCodeLabels.modifierGlyphs([.option]), "⌥")
        XCTAssertEqual(KeyCodeLabels.modifierGlyphs([.shift]), "⇧")
        XCTAssertEqual(KeyCodeLabels.modifierGlyphs([.shift, .command]), "⇧⌘")
        XCTAssertEqual(KeyCodeLabels.modifierGlyphs([.command, .shift, .option, .control]), "⌃⌥⇧⌘")
    }

    func test_combinedLabel_joinsGlyphsAndKeyNameWithSingleSpace() {
        XCTAssertEqual(KeyCodeLabels.label(for: 48, modifiers: [.option], fallback: nil), "⌥ Tab")
        XCTAssertEqual(KeyCodeLabels.label(for: 49, modifiers: [.shift, .command], fallback: nil), "⇧⌘ Space")
        XCTAssertEqual(KeyCodeLabels.label(for: 0, modifiers: [.control], fallback: "a"), "⌃ A")
        XCTAssertEqual(KeyCodeLabels.label(for: 7, modifiers: [.command], fallback: nil), "⌘ Key 7")
    }

    func test_combinedLabel_omitsGlyphsWhenNoModifiersAreBound() {
        XCTAssertEqual(KeyCodeLabels.label(for: 48, modifiers: [], fallback: nil), "Tab")
    }
}
