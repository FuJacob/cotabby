import ApplicationServices
import XCTest
@testable import Cotabby

/// Locks the human-readable shortcut labels rendered in the settings keycap and the ghost-text
/// hint pill. These strings are user-facing UI contracts, so each mapping is asserted exactly.
final class KeyCodeLabelsTests: XCTestCase {
    // MARK: - Special key names

    func test_label_mapsEditingKeysByKeyCode() {
        XCTAssertEqual(KeyCodeLabels.label(for: 48, fallback: nil), "Tab")
        XCTAssertEqual(KeyCodeLabels.label(for: 49, fallback: nil), "Space")
        XCTAssertEqual(KeyCodeLabels.label(for: 51, fallback: nil), "Delete")
        XCTAssertEqual(KeyCodeLabels.label(for: 53, fallback: nil), "Escape")
        XCTAssertEqual(KeyCodeLabels.label(for: 117, fallback: nil), "Forward Delete")
        XCTAssertEqual(KeyCodeLabels.label(for: 36, fallback: nil), "Return")
        XCTAssertEqual(KeyCodeLabels.label(for: 76, fallback: nil), "Enter")
    }

    func test_label_mapsArrowAndFunctionKeys() {
        XCTAssertEqual(KeyCodeLabels.label(for: 123, fallback: nil), "Left Arrow")
        XCTAssertEqual(KeyCodeLabels.label(for: 124, fallback: nil), "Right Arrow")
        XCTAssertEqual(KeyCodeLabels.label(for: 125, fallback: nil), "Down Arrow")
        XCTAssertEqual(KeyCodeLabels.label(for: 126, fallback: nil), "Up Arrow")
        XCTAssertEqual(KeyCodeLabels.label(for: 122, fallback: nil), "F1")
        XCTAssertEqual(KeyCodeLabels.label(for: 100, fallback: nil), "F8")
        XCTAssertEqual(KeyCodeLabels.label(for: 111, fallback: nil), "F12")
    }

    func test_label_prefersSpecialNameOverFallbackCharacters() {
        // Tab must never render as a literal tab character even if the event carried one.
        XCTAssertEqual(KeyCodeLabels.label(for: 48, fallback: "\t"), "Tab")
        XCTAssertEqual(KeyCodeLabels.label(for: 49, fallback: " "), "Space")
    }

    // MARK: - Fallback characters

    func test_label_uppercasesAndTrimsFallbackCharacters() {
        XCTAssertEqual(KeyCodeLabels.label(for: 0, fallback: "a"), "A")
        XCTAssertEqual(KeyCodeLabels.label(for: 6, fallback: " z "), "Z")
        XCTAssertEqual(KeyCodeLabels.label(for: 18, fallback: "1"), "1")
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
        XCTAssertEqual(KeyCodeLabels.label(for: 7, fallback: " "), "Key 7")
    }

    // MARK: - Modifier glyphs

    func test_modifierGlyphs_followMacOSConventionOrdering() {
        // Control, Option, Shift, Command: the order macOS renders in menus, regardless of the
        // order the caller assembled the mask in.
        XCTAssertEqual(KeyCodeLabels.modifierGlyphs([]), "")
        XCTAssertEqual(KeyCodeLabels.modifierGlyphs([.command]), "⌘")
        XCTAssertEqual(KeyCodeLabels.modifierGlyphs([.control]), "⌃")
        XCTAssertEqual(KeyCodeLabels.modifierGlyphs([.shift, .command]), "⇧⌘")
        XCTAssertEqual(KeyCodeLabels.modifierGlyphs([.command, .shift, .option, .control]), "⌃⌥⇧⌘")
    }

    func test_combinedLabel_joinsGlyphsAndKeyNameWithSingleSpace() {
        XCTAssertEqual(KeyCodeLabels.label(for: 48, modifiers: [.option], fallback: nil), "⌥ Tab")
        XCTAssertEqual(KeyCodeLabels.label(for: 49, modifiers: [.shift, .command], fallback: nil), "⇧⌘ Space")
        XCTAssertEqual(KeyCodeLabels.label(for: 0, modifiers: [.control], fallback: "a"), "⌃ A")
    }

    func test_combinedLabel_omitsGlyphsWhenNoModifiersAreBound() {
        XCTAssertEqual(KeyCodeLabels.label(for: 48, modifiers: [], fallback: nil), "Tab")
    }
}
