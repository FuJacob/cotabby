import Foundation
import XCTest
@testable import Cotabby

/// Tests for the emoji picker value models: match identity under variant overrides and the
/// skin-tone / gender modifiers, settings copy, and sample glyphs.
final class EmojiPickerModelsTests: XCTestCase {
    func test_emojiMatch_defaultsDisplayGlyphToEntryGlyphAndUsesItAsIdentity() {
        let match = EmojiMatch(entry: makeEntry())

        XCTAssertEqual(match.displayGlyph, "\u{1F44B}")
        XCTAssertEqual(match.glyph, "\u{1F44B}")
        XCTAssertEqual(match.id, "\u{1F44B}")
    }

    func test_emojiMatch_variantOverrideChangesIdentityButKeepsSourceEntry() {
        let base = makeEntry()
        let toned = EmojiMatch(entry: base, displayGlyph: "\u{1F44B}\u{1F3FD}")

        // A neutral row and its skin-toned sibling share the entry but must stay distinct
        // SwiftUI list rows, so identity follows the displayed glyph.
        XCTAssertEqual(toned.id, "\u{1F44B}\u{1F3FD}")
        XCTAssertEqual(toned.glyph, "\u{1F44B}\u{1F3FD}")
        XCTAssertEqual(toned.entry, base)
    }

    func test_emojiSkinTone_modifiersAreTheFitzpatrickScalarsInLightToDarkOrder() {
        XCTAssertEqual(
            EmojiSkinTone.allCases.map(\.modifier),
            [nil, "\u{1F3FB}", "\u{1F3FC}", "\u{1F3FD}", "\u{1F3FE}", "\u{1F3FF}"]
        )
    }

    func test_emojiSkinTone_sampleGlyphAppendsModifierAndNeutralKeepsVariationSelector() throws {
        // Without U+FE0F the neutral victory hand can render as the plain text symbol.
        XCTAssertEqual(EmojiSkinTone.neutral.sampleGlyph, "\u{270C}\u{FE0F}")

        for tone in EmojiSkinTone.allCases where tone != .neutral {
            let modifier = try XCTUnwrap(tone.modifier, "\(tone) should carry a Fitzpatrick modifier")
            XCTAssertEqual(tone.sampleGlyph, "\u{270C}" + modifier)
        }
    }

    private func makeEntry() -> EmojiEntry {
        EmojiEntry(
            glyph: "\u{1F44B}",
            name: "waving hand",
            aliases: ["wave"],
            keywords: ["hello"]
        )
    }
}
