import XCTest
@testable import Cotabby

/// Tests for the bare-`:` suggestion builder: recents first, popularity-padded, de-duplicated and
/// resolved against the catalog.
final class EmojiRecentsTests: XCTestCase {
    private func entry(_ glyph: String, _ alias: String) -> EmojiEntry {
        EmojiEntry(glyph: glyph, name: alias, aliases: [alias], keywords: [], group: "Test", unicodeVersion: "1.0")
    }

    private func sampleCatalog() -> EmojiCatalog {
        EmojiCatalog(entries: [
            entry("😀", "grinning"),   // not in the popularity prior
            entry("😂", "joy"),        // popular
            entry("❤️", "heart"),      // popular
            entry("🚀", "rocket"),     // popular
            entry("🦄", "unicorn")     // popular (animals section)
        ])
    }

    func test_recentsLeadInOrderThenPopularityPads() {
        let usage = EmojiUsageSnapshot(recentAliases: ["unicorn", "grinning"], frequency: [:])
        let glyphs = EmojiRecents.suggestions(usage: usage, catalog: sampleCatalog(), limit: 10).map { $0.glyph }

        XCTAssertEqual(Array(glyphs.prefix(2)), ["🦄", "😀"])   // recents first, most-recent first
        XCTAssertTrue(glyphs.contains("😂"))                    // joy padded in from the popularity prior
        XCTAssertEqual(glyphs.count, Set(glyphs).count)         // no duplicates
    }

    func test_emptyUsageFallsBackToPopularityAndDropsUnpopular() {
        let glyphs = EmojiRecents.suggestions(usage: .empty, catalog: sampleCatalog(), limit: 10).map { $0.glyph }

        XCTAssertTrue(glyphs.contains("😂"))    // joy is in the popularity prior
        XCTAssertFalse(glyphs.contains("😀"))   // grinning is neither recent nor popular
    }

    func test_unresolvableRecentAliasIsSkipped() {
        let usage = EmojiUsageSnapshot(recentAliases: ["not_in_catalog", "joy"], frequency: [:])
        let glyphs = EmojiRecents.suggestions(usage: usage, catalog: sampleCatalog(), limit: 5).map { $0.glyph }

        XCTAssertEqual(glyphs.first, "😂")   // the unresolvable alias is skipped, joy leads
    }

    func test_limitIsRespected() {
        XCTAssertEqual(EmojiRecents.suggestions(usage: .empty, catalog: sampleCatalog(), limit: 2).count, 2)
    }
}
