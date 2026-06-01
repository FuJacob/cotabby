import XCTest
@testable import Cotabby

/// Tests for the curated popularity prior used as a ranking tiebreak and the bare-`:` starter set.
final class EmojiPopularityTests: XCTestCase {
    func test_rankIsAscendingByListPosition() {
        // "joy" leads the curated list, so it must rank ahead of a later entry like "heart".
        XCTAssertLessThan(
            EmojiPopularity.rank(forAlias: "joy"),
            EmojiPopularity.rank(forAlias: "heart")
        )
    }

    func test_absentAliasIsNotRanked() {
        XCTAssertEqual(
            EmojiPopularity.rank(forAlias: "definitely_not_an_emoji_alias"),
            EmojiPopularity.notRanked
        )
    }

    func test_rankIsCaseInsensitive() {
        XCTAssertEqual(EmojiPopularity.rank(forAlias: "JOY"), EmojiPopularity.rank(forAlias: "joy"))
    }

    func test_starterAliasesReturnsPrefixInOrder() {
        XCTAssertEqual(EmojiPopularity.starterAliases(limit: 3), Array(EmojiPopularity.ordered.prefix(3)))
    }

    func test_starterAliasesClampsToZero() {
        XCTAssertTrue(EmojiPopularity.starterAliases(limit: 0).isEmpty)
        XCTAssertTrue(EmojiPopularity.starterAliases(limit: -5).isEmpty)
    }
}
