import XCTest
@testable import Cotabby

/// Tests for the pure emoji search layer.
///
/// Ranking is the part most likely to drift, so these lock down the contract the picker relies on:
/// exact aliases win, prefixes beat substrings, shorter matched tokens come first, keywords widen
/// recall, and an empty query yields nothing. A final test confirms the bundled dataset is packaged
/// and decodes.
final class EmojiCatalogMatcherTests: XCTestCase {

    private func entry(
        _ glyph: String,
        _ name: String,
        aliases: [String],
        keywords: [String] = []
    ) -> EmojiEntry {
        EmojiEntry(
            glyph: glyph,
            name: name,
            aliases: aliases,
            keywords: keywords,
            group: "Test",
            unicodeVersion: "1.0"
        )
    }

    private func matcher(_ entries: [EmojiEntry]) -> EmojiMatcher {
        EmojiMatcher(catalog: EmojiCatalog(entries: entries))
    }

    // MARK: - Ranking

    func test_exactAliasOutranksPrefix() {
        let sut = matcher([
            entry("😄", "smiley", aliases: ["smiley"]),
            entry("🙂", "slight smile", aliases: ["smile"])
        ])

        let results = sut.matches(for: "smile")

        XCTAssertEqual(results.first?.glyph, "🙂", "Exact alias match must rank first")
    }

    func test_prefixBeatsSubstring() {
        let sut = matcher([
            entry("🐻", "bear", aliases: ["bear"]),       // substring of "ear"
            entry("🌍", "earth", aliases: ["earth"]),     // prefix of "ear"
            entry("👂", "ear", aliases: ["ear"])          // exact "ear"
        ])

        let glyphs = sut.matches(for: "ear").map { $0.glyph }

        XCTAssertEqual(glyphs, ["👂", "🌍", "🐻"])
    }

    func test_shorterMatchedTokenRanksFirstWithinTier() {
        let sut = matcher([
            entry("😄", "smiley", aliases: ["smiley"]),
            entry("🙂", "smile", aliases: ["smile"])
        ])

        // Both are prefix matches for "smil"; the shorter alias should come first.
        let glyphs = sut.matches(for: "smil").map { $0.glyph }

        XCTAssertEqual(glyphs, ["🙂", "😄"])
    }

    func test_keywordWidensRecallWhenAliasDoesNotMatch() {
        let sut = matcher([
            entry("🎉", "party popper", aliases: ["tada"], keywords: ["party", "celebrate"])
        ])

        let results = sut.matches(for: "party")

        XCTAssertEqual(results.first?.glyph, "🎉")
    }

    // MARK: - Bounds

    func test_emptyQueryReturnsNothing() {
        let sut = matcher([entry("😀", "grinning", aliases: ["grinning"])])

        XCTAssertTrue(sut.matches(for: "").isEmpty)
        XCTAssertTrue(sut.matches(for: "   ").isEmpty)
    }

    func test_limitIsRespected() {
        let entries = (0..<50).map { entry("E\($0)", "alpha \($0)", aliases: ["alpha\($0)"]) }
        let sut = matcher(entries)

        XCTAssertEqual(sut.matches(for: "alpha", limit: 5).count, 5)
    }

    func test_noMatchReturnsEmpty() {
        let sut = matcher([entry("😀", "grinning", aliases: ["grinning"])])

        XCTAssertTrue(sut.matches(for: "zzzznope").isEmpty)
    }

    // MARK: - Bundled dataset

    func test_bundledCatalogLoadsAndDecodes() {
        let catalog = EmojiCatalog.bundled()

        XCTAssertFalse(catalog.isEmpty, "Bundled emoji.json should be packaged and decode")
        let matcher = EmojiMatcher(catalog: catalog)
        XCTAssertEqual(matcher.matches(for: "grinning").first?.glyph, "😀")
    }
}
