import XCTest
@testable import Cotabby

/// Tests for the curated intent/slang overlay that boosts canonical aliases for words people type.
final class EmojiSynonymCatalogTests: XCTestCase {
    func test_exactKeyBoostsExactlyItsMappedAliases() {
        let boosted = EmojiSynonymCatalog.boostedAliases(for: "lol")
        XCTAssertEqual(boosted.exact, ["joy", "rofl"])
        // "lol" is not a proper prefix of any other key.
        XCTAssertTrue(boosted.prefix.isEmpty)
    }

    func test_queryIsTrimmedAndCaseFolded() {
        XCTAssertEqual(EmojiSynonymCatalog.boostedAliases(for: "  LOL ").exact, ["joy", "rofl"])
    }

    func test_mapKeysAndValuesAreLowercase() {
        // The query is lowercased before lookup and aliases are compared lowercased, so any
        // mixed-case entry here would be unreachable.
        for (key, aliases) in EmojiSynonymCatalog.map {
            XCTAssertEqual(key, key.lowercased(), key)
            for alias in aliases {
                XCTAssertEqual(alias, alias.lowercased(), "\(key) -> \(alias)")
            }
        }
    }

    func test_prefixKeyBoostsViaPrefix() {
        // "lo" is a prefix of "lol" -> joy and "love" -> heart.
        let boosted = EmojiSynonymCatalog.boostedAliases(for: "lo")
        XCTAssertTrue(boosted.prefix.contains("joy"))
        XCTAssertTrue(boosted.prefix.contains("heart"))
    }

    func test_prefixExcludesExact() {
        // "love" is an exact key; its aliases must not be duplicated into the prefix set.
        let boosted = EmojiSynonymCatalog.boostedAliases(for: "love")
        XCTAssertTrue(boosted.exact.contains("heart"))
        XCTAssertTrue(boosted.exact.isDisjoint(with: boosted.prefix))
    }

    func test_singleCharacterDoesNotPrefixBoost() {
        XCTAssertTrue(EmojiSynonymCatalog.boostedAliases(for: "l").prefix.isEmpty)
    }

    func test_blankQueryBoostsNothing() {
        let boosted = EmojiSynonymCatalog.boostedAliases(for: "   ")
        XCTAssertTrue(boosted.exact.isEmpty)
        XCTAssertTrue(boosted.prefix.isEmpty)
    }
}
