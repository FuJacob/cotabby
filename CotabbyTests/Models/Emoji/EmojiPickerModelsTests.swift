import Foundation
import XCTest
@testable import Cotabby

/// Tests for the emoji picker value models: match identity under variant overrides, alias
/// fallbacks, and the skin-tone / gender settings copy and sample glyphs.
final class EmojiPickerModelsTests: XCTestCase {
    func test_emojiMatch_defaultsDisplayGlyphToEntryGlyphAndUsesItAsIdentity() {
        let match = EmojiMatch(entry: makeEntry())

        XCTAssertEqual(match.displayGlyph, "\u{1F44B}")
        XCTAssertEqual(match.glyph, "\u{1F44B}")
        XCTAssertEqual(match.id, "\u{1F44B}")
        XCTAssertEqual(match.primaryAlias, "wave")
    }

    func test_emojiMatch_variantOverrideChangesIdentityButKeepsSourceEntry() {
        let base = makeEntry()
        let toned = EmojiMatch(entry: base, displayGlyph: "\u{1F44B}\u{1F3FD}")

        // A neutral row and its skin-toned sibling share the entry but must stay distinct
        // SwiftUI list rows, so identity follows the displayed glyph.
        XCTAssertEqual(toned.id, "\u{1F44B}\u{1F3FD}")
        XCTAssertEqual(toned.glyph, "\u{1F44B}\u{1F3FD}")
        XCTAssertEqual(toned.entry, base)
        XCTAssertEqual(toned.primaryAlias, "wave")
    }

    func test_emojiMatch_primaryAliasFallsBackToNameWhenEntryHasNoAliases() {
        let match = EmojiMatch(entry: makeEntry(aliases: []))
        XCTAssertEqual(match.primaryAlias, "waving hand")
    }

    func test_emojiSkinTone_displayNamesArePinnedSettingsCopy() {
        XCTAssertEqual(EmojiSkinTone.neutral.displayName, "Default")
        XCTAssertEqual(EmojiSkinTone.light.displayName, "Light")
        XCTAssertEqual(EmojiSkinTone.mediumLight.displayName, "Medium Light")
        XCTAssertEqual(EmojiSkinTone.medium.displayName, "Medium")
        XCTAssertEqual(EmojiSkinTone.mediumDark.displayName, "Medium Dark")
        XCTAssertEqual(EmojiSkinTone.dark.displayName, "Dark")
    }

    func test_emojiSkinTone_sampleGlyphAppendsModifierAndNeutralKeepsVariationSelector() throws {
        // Without U+FE0F the neutral victory hand can render as the plain text symbol.
        XCTAssertEqual(EmojiSkinTone.neutral.sampleGlyph, "\u{270C}\u{FE0F}")

        for tone in EmojiSkinTone.allCases where tone != .neutral {
            let modifier = try XCTUnwrap(tone.modifier, "\(tone) should carry a Fitzpatrick modifier")
            XCTAssertEqual(tone.sampleGlyph, "\u{270C}" + modifier)
        }
    }

    func test_emojiGender_displayNamesArePinnedSettingsCopy() {
        XCTAssertEqual(EmojiGender.neutral.displayName, "Person")
        XCTAssertEqual(EmojiGender.male.displayName, "Man")
        XCTAssertEqual(EmojiGender.female.displayName, "Woman")
    }

    func test_emojiGender_sampleGlyphsAreTheBasePersonManWomanScalars() {
        XCTAssertEqual(EmojiGender.neutral.sampleGlyph, "\u{1F9D1}")
        XCTAssertEqual(EmojiGender.male.sampleGlyph, "\u{1F468}")
        XCTAssertEqual(EmojiGender.female.sampleGlyph, "\u{1F469}")
    }

    private func makeEntry(aliases: [String] = ["wave"]) -> EmojiEntry {
        EmojiEntry(
            glyph: "\u{1F44B}",
            name: "waving hand",
            aliases: aliases,
            keywords: ["hello"],
            group: "People & Body",
            unicodeVersion: "6.0"
        )
    }
}
