import XCTest
@testable import Cotabby

/// Tests the pure skin-tone / gender variant policy applied to matcher results. Glyphs are written
/// as explicit Unicode scalars so the expectations are unambiguous about modifier placement.
final class EmojiVariantResolverTests: XCTestCase {
    private func match(glyph: String, name: String, aliases: [String]) -> EmojiMatch {
        EmojiMatch(
            entry: EmojiEntry(
                glyph: glyph,
                name: name,
                aliases: aliases,
                keywords: []
            )
        )
    }

    private func prefs(
        skinTone: EmojiSkinTone = .neutral,
        gender: EmojiGender = .neutral
    ) -> EmojiVariantPreferences {
        EmojiVariantPreferences(skinTone: skinTone, gender: gender)
    }

    // MARK: - Skin tone

    func test_skinTone_keepsDefaultVariantAfterPreferredTone() {
        let wave = match(glyph: "\u{1F44B}", name: "waving hand", aliases: ["wave"])
        let resolved = EmojiVariantResolver.resolve([wave], preferences: prefs(skinTone: .medium))
        XCTAssertEqual(resolved.map(\.glyph), ["\u{1F44B}\u{1F3FD}", "\u{1F44B}"])
    }

    func test_skinTone_leavesUnsupportedEmojiUntoned() {
        let dog = match(glyph: "\u{1F436}", name: "dog face", aliases: ["dog"])
        let resolved = EmojiVariantResolver.resolve([dog], preferences: prefs(skinTone: .dark))
        XCTAssertEqual(resolved.map(\.glyph), ["\u{1F436}"])
    }

    func test_skinTone_neutralLeavesGlyphsUnchanged() {
        let wave = match(glyph: "\u{1F44B}", name: "waving hand", aliases: ["wave"])
        let resolved = EmojiVariantResolver.resolve([wave], preferences: prefs())
        XCTAssertEqual(resolved.map(\.glyph), ["\u{1F44B}"])
    }

    func test_skinTone_appliesAfterTheLeadingPersonScalarInsideZWJSequence() {
        // 🧑‍🚒 -> 🧑🏽‍🚒: modifier after the person scalar, before the ZWJ.
        let firefighter = match(glyph: "\u{1F9D1}\u{200D}\u{1F692}", name: "firefighter", aliases: ["firefighter"])
        let resolved = EmojiVariantResolver.resolve([firefighter], preferences: prefs(skinTone: .medium))
        XCTAssertEqual(
            resolved.map(\.glyph),
            ["\u{1F9D1}\u{1F3FD}\u{200D}\u{1F692}", "\u{1F9D1}\u{200D}\u{1F692}"]
        )
    }

    func test_skinTone_tonedRowKeepsTheSourceEntry() {
        // Ranking and the `:alias:` label read `entry`, so only the displayed glyph may change.
        let wave = match(glyph: "\u{1F44B}", name: "waving hand", aliases: ["wave"])
        let resolved = EmojiVariantResolver.resolve([wave], preferences: prefs(skinTone: .light))
        XCTAssertEqual(resolved.map(\.entry), [wave.entry, wave.entry])
        XCTAssertEqual(resolved.first?.id, "\u{1F44B}\u{1F3FB}")
    }

    func test_tonedGlyph_refusesAlreadyTonedOrUnsupportedGlyphs() {
        let medium = EmojiSkinTone.medium.modifier!
        XCTAssertNil(EmojiVariantResolver.tonedGlyph("\u{1F44B}\u{1F3FF}", modifier: medium))
        XCTAssertNil(EmojiVariantResolver.tonedGlyph("\u{1F436}", modifier: medium))
        XCTAssertNil(EmojiVariantResolver.tonedGlyph("", modifier: medium))
    }

    func test_isModifierBase_matchesRangeEdges() {
        XCTAssertTrue(EmojiVariantResolver.isModifierBase("\u{261D}"))    // index pointing up
        XCTAssertTrue(EmojiVariantResolver.isModifierBase("\u{1FAF8}"))   // last range end
        XCTAssertFalse(EmojiVariantResolver.isModifierBase("\u{1F3FB}"))  // a modifier is not a base
        XCTAssertFalse(EmojiVariantResolver.isModifierBase("a"))
    }

    // MARK: - Gender

    func test_gender_prefersConfiguredVariantAndCollapsesTheFamily() {
        let family = [
            match(glyph: "\u{1F9D1}\u{200D}\u{1F692}", name: "firefighter", aliases: ["firefighter"]),
            match(glyph: "\u{1F468}\u{200D}\u{1F692}", name: "man firefighter", aliases: ["man_firefighter"]),
            match(glyph: "\u{1F469}\u{200D}\u{1F692}", name: "woman firefighter", aliases: ["woman_firefighter"])
        ]
        XCTAssertEqual(
            EmojiVariantResolver.resolve(family, preferences: prefs(gender: .female)).map(\.glyph),
            ["\u{1F469}\u{200D}\u{1F692}"]
        )
        XCTAssertEqual(
            EmojiVariantResolver.resolve(family, preferences: prefs(gender: .male)).map(\.glyph),
            ["\u{1F468}\u{200D}\u{1F692}"]
        )
        XCTAssertEqual(
            EmojiVariantResolver.resolve(family, preferences: prefs()).map(\.glyph),
            ["\u{1F9D1}\u{200D}\u{1F692}"]
        )
    }

    func test_gender_fallsBackToNeutralWhenPreferredVariantMissing() {
        let partial = [
            match(glyph: "\u{1F9D1}\u{200D}\u{1F692}", name: "firefighter", aliases: ["firefighter"]),
            match(glyph: "\u{1F468}\u{200D}\u{1F692}", name: "man firefighter", aliases: ["man_firefighter"])
        ]
        XCTAssertEqual(
            EmojiVariantResolver.resolve(partial, preferences: prefs(gender: .female)).map(\.glyph),
            ["\u{1F9D1}\u{200D}\u{1F692}"]
        )
    }

    func test_gender_singleGenderedVariantPassesThrough() {
        // With only one member of a family present there is nothing to collapse, so a female
        // preference still shows the lone male variant rather than dropping it.
        let lone = [match(glyph: "\u{1F468}\u{200D}\u{1F692}", name: "man firefighter", aliases: ["man_firefighter"])]
        XCTAssertEqual(
            EmojiVariantResolver.resolve(lone, preferences: prefs(gender: .female)).map(\.glyph),
            ["\u{1F468}\u{200D}\u{1F692}"]
        )
    }

    func test_genderIsResolvedBeforeSkinTone() {
        let family = [
            match(glyph: "\u{1F9D1}\u{200D}\u{1F692}", name: "firefighter", aliases: ["firefighter"]),
            match(glyph: "\u{1F469}\u{200D}\u{1F692}", name: "woman firefighter", aliases: ["woman_firefighter"])
        ]
        XCTAssertEqual(
            EmojiVariantResolver.resolve(family, preferences: prefs(skinTone: .dark, gender: .female)).map(\.glyph),
            ["\u{1F469}\u{1F3FF}\u{200D}\u{1F692}", "\u{1F469}\u{200D}\u{1F692}"]
        )
    }

    func test_gender_leavesNonGenderedEmojiUntouched() {
        let matches = [
            match(glyph: "\u{1F604}", name: "smile", aliases: ["smile"]),
            match(glyph: "\u{1F436}", name: "dog", aliases: ["dog"])
        ]
        XCTAssertEqual(
            EmojiVariantResolver.resolve(matches, preferences: prefs(gender: .male)).map(\.glyph),
            ["\u{1F604}", "\u{1F436}"]
        )
    }
}
