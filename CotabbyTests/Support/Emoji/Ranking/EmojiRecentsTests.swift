import XCTest
@testable import Cotabby

/// Tests for the bare-`:` suggestion builder: recents first, popularity-padded, de-duplicated and
/// resolved against the catalog.
///
/// The padding window is `limit * 3` aliases of `EmojiPopularity.ordered`, so expectations below are
/// derived from list positions: joy = 0, heart = 1, rocket = 25, unicorn is far past the window.
final class EmojiRecentsTests: XCTestCase {
    private func entry(_ glyph: String, _ alias: String) -> EmojiEntry {
        EmojiEntry(glyph: glyph, name: alias, aliases: [alias], keywords: [])
    }

    private func sampleCatalog() -> EmojiCatalog {
        EmojiCatalog(entries: [
            entry("😀", "grinning"),   // not in the popularity prior
            entry("😂", "joy"),        // popularity rank 0
            entry("❤️", "heart"),      // popularity rank 1
            entry("🚀", "rocket"),     // popularity rank 25
            entry("🦄", "unicorn")     // popular, but far outside a small padding window
        ])
    }

    private func glyphs(_ usage: EmojiUsageSnapshot, limit: Int) -> [String] {
        EmojiRecents.suggestions(usage: usage, catalog: sampleCatalog(), limit: limit).map(\.glyph)
    }

    func test_recentsLeadInOrderThenPopularityPads() {
        let usage = EmojiUsageSnapshot(recentAliases: ["unicorn", "grinning"], frequency: [:])

        // Recents (most recent first), then the prior's first 30 aliases that exist in the catalog.
        XCTAssertEqual(glyphs(usage, limit: 10), ["🦄", "😀", "😂", "❤️", "🚀"])
    }

    func test_emptyUsageUsesOnlyThePopularityWindow() {
        // grinning is neither recent nor popular; unicorn is popular but outside the 30-alias window.
        XCTAssertEqual(glyphs(.empty, limit: 10), ["😂", "❤️", "🚀"])
    }

    func test_paddingWindowScalesWithLimit() {
        // limit 5 pads from the first 15 aliases, which reach joy and heart but not rocket (25).
        XCTAssertEqual(glyphs(.empty, limit: 5), ["😂", "❤️"])
    }

    func test_unresolvableRecentAliasIsSkipped() {
        let usage = EmojiUsageSnapshot(recentAliases: ["not_in_catalog", "joy"], frequency: [:])

        XCTAssertEqual(glyphs(usage, limit: 5), ["😂", "❤️"])
    }

    func test_recentThatIsAlsoPopularAppearsOnceAtItsRecentPosition() {
        // Dedup is case-insensitive, so a stored "HEART" recent suppresses the prior's "heart".
        let usage = EmojiUsageSnapshot(recentAliases: ["HEART"], frequency: [:])

        XCTAssertEqual(glyphs(usage, limit: 10), ["❤️", "😂", "🚀"])
    }

    func test_limitIsRespected() {
        XCTAssertEqual(glyphs(.empty, limit: 2), ["😂", "❤️"])
        XCTAssertEqual(glyphs(EmojiUsageSnapshot(recentAliases: ["unicorn", "grinning"], frequency: [:]), limit: 1), ["🦄"])
    }

    func test_nonPositiveLimitReturnsNothing() {
        XCTAssertTrue(glyphs(.empty, limit: 0).isEmpty)
        XCTAssertTrue(glyphs(.empty, limit: -1).isEmpty)
    }
}
