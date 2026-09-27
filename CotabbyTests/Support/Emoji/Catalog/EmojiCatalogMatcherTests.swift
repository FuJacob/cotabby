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
            keywords: keywords
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

    func test_aliasSubstringBeatsKeywordSubstring() {
        // Neither entry has a prefix hit for "art"; alias substrings (tier 3) outrank keyword
        // substrings (tier 4) regardless of token length.
        let sut = matcher([
            entry("🎨", "palette", aliases: ["palette"], keywords: ["smart"]),
            entry("💓", "beating heart", aliases: ["heartbeat"])
        ])

        XCTAssertEqual(sut.matches(for: "art").map(\.glyph), ["💓", "🎨"])
    }

    func test_nameMatchesWhenAliasAndKeywordsDoNot() {
        let sut = matcher([entry("🧭", "compass rose", aliases: ["compass"])])

        XCTAssertEqual(sut.matches(for: "rose").first?.glyph, "🧭")
    }

    func test_queryIsTrimmedAndCaseFolded() {
        let sut = matcher([entry("🙂", "slight smile", aliases: ["smile"])])

        XCTAssertEqual(sut.matches(for: "  SMILE ").map(\.glyph), ["🙂"])
    }

    // MARK: - Synonyms, fuzzy, and personalization

    func test_exactSynonymLeadsLiteralAliasPrefixInTheSameTier() {
        // "lol" is an alias prefix of "lollipop" and an exact synonym for "joy". Both land in tier 1,
        // and the synonym's zero token length puts the intended emoji first.
        let sut = matcher([
            entry("🍭", "lollipop", aliases: ["lollipop"]),
            entry("😂", "face with tears of joy", aliases: ["joy"])
        ])

        XCTAssertEqual(sut.matches(for: "lol").map(\.glyph), ["😂", "🍭"])
    }

    func test_fuzzyFallbackOnlyRunsWhenLexicalResultsAreSparse() {
        let sut = matcher([
            entry("🥳", "hapyness", aliases: ["hapyness"]),   // alias prefix of "hapy"
            entry("😀", "happy face", aliases: ["happy"])      // only a fuzzy candidate
        ])

        XCTAssertEqual(sut.matches(for: "hapy", limit: 1).map(\.glyph), ["🥳"])
        XCTAssertEqual(sut.matches(for: "hapy", limit: 5).map(\.glyph), ["🥳", "😀"])
    }

    func test_fuzzyNeedsAtLeastThreeCharacters() {
        let sut = matcher([entry("😀", "happy face", aliases: ["happy"])])

        XCTAssertTrue(sut.matches(for: "hp").isEmpty)
        // At three characters the subsequence rule kicks in (h-p-y appear in order in "happy").
        XCTAssertEqual(sut.matches(for: "hpy").first?.glyph, "😀")
    }

    func test_frequentUseAloneMarksAFavorite() {
        let sut = matcher([
            entry("🅰️", "alpha", aliases: ["alpha"]),
            entry("🅱️", "alphabet", aliases: ["alphabet"])
        ])

        let once = EmojiUsageSnapshot(recentAliases: [], frequency: ["alphabet": 1])
        XCTAssertEqual(sut.matches(for: "alph", usage: once).first?.glyph, "🅰️")

        let often = EmojiUsageSnapshot(recentAliases: [], frequency: ["alphabet": EmojiUsageSnapshot.frequentThreshold])
        XCTAssertEqual(sut.matches(for: "alph", usage: often).first?.glyph, "🅱️")
    }

    func test_favoriteNeverJumpsAStrongerTier() {
        let sut = matcher([
            entry("🅰️", "alpha", aliases: ["alpha"]),        // exact alias
            entry("🅱️", "alphabet", aliases: ["alphabet"])   // prefix only
        ])
        let usage = EmojiUsageSnapshot(recentAliases: ["alphabet"], frequency: [:])

        XCTAssertEqual(sut.matches(for: "alpha", usage: usage).first?.glyph, "🅰️")
    }

    func test_catalogOrderIsTheFinalTiebreak() {
        // Same tier, same token length, neither popular nor favorite: input order decides.
        let sut = matcher([
            entry("1️⃣", "zork one", aliases: ["zorka"]),
            entry("2️⃣", "zork two", aliases: ["zorkb"])
        ])

        XCTAssertEqual(sut.matches(for: "zork").map(\.glyph), ["1️⃣", "2️⃣"])
    }

    func test_synonymSurfacesIntentWordWithNoLexicalMatch() {
        // "lol" is not an alias, keyword, or name of 😂, but the synonym overlay maps it to "joy".
        let sut = matcher([
            entry("🎈", "balloon", aliases: ["balloon"]),
            entry("😂", "face with tears of joy", aliases: ["joy"])
        ])

        XCTAssertEqual(sut.matches(for: "lol").first?.glyph, "😂")
    }

    func test_fuzzyMatchesDroppedLetterTypo() {
        let sut = matcher([entry("😀", "happy face", aliases: ["happy"])])

        XCTAssertEqual(sut.matches(for: "hapy").first?.glyph, "😀")
    }

    func test_fuzzyMatchesTransposition() {
        let sut = matcher([entry("📥", "incoming", aliases: ["receive"])])

        XCTAssertEqual(sut.matches(for: "recieve").first?.glyph, "📥")
    }

    func test_exactMatchStillBeatsFuzzy() {
        // A literal exact alias must always outrank a fuzzy hit on another entry.
        let sut = matcher([
            entry("😀", "happy face", aliases: ["happy"]),   // only a fuzzy candidate for "hapy"
            entry("🅷", "hapy tag", aliases: ["hapy"])        // exact alias "hapy"
        ])

        XCTAssertEqual(sut.matches(for: "hapy").first?.glyph, "🅷")
    }

    func test_favoriteFloatsAboveShorterTokenWithinTier() {
        let sut = matcher([
            entry("🅰️", "alpha", aliases: ["alpha"]),       // shorter token, normally first
            entry("🅱️", "alphabet", aliases: ["alphabet"])  // longer token
        ])

        // Without history, the shorter "alpha" leads for "alph".
        XCTAssertEqual(sut.matches(for: "alph").first?.glyph, "🅰️")

        // Marking "alphabet" a recent favorite lifts it above the shorter token within the same tier.
        let usage = EmojiUsageSnapshot(recentAliases: ["alphabet"], frequency: [:])
        XCTAssertEqual(sut.matches(for: "alph", usage: usage).first?.glyph, "🅱️")
    }

    func test_popularityBreaksTiesAtEqualRelevance() {
        let sut = matcher([
            entry("🌿", "hedge", aliases: ["hedge"]),   // not in the popularity prior
            entry("❤️", "heart", aliases: ["heart"])    // high in the popularity prior
        ])

        // Both are equal-length prefix matches for "he"; the more popular alias wins the tiebreak.
        XCTAssertEqual(sut.matches(for: "he").first?.glyph, "❤️")
    }

    func test_recentsLeadBareColonSuggestions() {
        let sut = matcher([
            entry("😀", "grinning", aliases: ["grinning"]),
            entry("😂", "joy", aliases: ["joy"])
        ])
        let usage = EmojiUsageSnapshot(recentAliases: ["grinning"], frequency: [:])

        XCTAssertEqual(sut.recents(usage: usage).first?.glyph, "😀")
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
        XCTAssertTrue(sut.matches(for: "alpha", limit: 0).isEmpty)
    }

    func test_noMatchReturnsEmpty() {
        let sut = matcher([entry("😀", "grinning", aliases: ["grinning"])])

        XCTAssertTrue(sut.matches(for: "zzzznope").isEmpty)
    }

    // MARK: - Bundled dataset

    func test_bundledCatalogLoadsAndDecodes() {
        let catalog = EmojiCatalog.bundled()

        XCTAssertFalse(catalog.indexed.isEmpty, "Bundled emoji.json should be packaged and decode")
        let matcher = EmojiMatcher(catalog: catalog)
        XCTAssertEqual(matcher.matches(for: "grinning").first?.glyph, "😀")
    }
}
