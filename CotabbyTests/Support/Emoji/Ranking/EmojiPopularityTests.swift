import XCTest
@testable import Cotabby

/// Tests for the curated popularity prior used as a ranking tiebreak and the bare-`:` starter set.
final class EmojiPopularityTests: XCTestCase {
    func test_rankIsTheListIndex() {
        XCTAssertEqual(EmojiPopularity.rank(forAlias: "joy"), 0)
        XCTAssertEqual(EmojiPopularity.rank(forAlias: "heart"), 1)
        for (index, alias) in EmojiPopularity.ordered.enumerated() {
            XCTAssertEqual(EmojiPopularity.rank(forAlias: alias), index, alias)
        }
    }

    func test_orderedListHasNoDuplicatesAndIsLowercase() {
        // A duplicate would be silently shadowed by its first occurrence, and a mixed-case entry
        // would never match the lowercased aliases the matcher ranks with.
        let ordered = EmojiPopularity.ordered
        XCTAssertEqual(Set(ordered).count, ordered.count)
        for alias in ordered {
            XCTAssertEqual(alias, alias.lowercased(), alias)
        }
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

    func test_starterAliasesLimitBeyondListReturnsWholeList() {
        XCTAssertEqual(EmojiPopularity.starterAliases(limit: EmojiPopularity.ordered.count + 10), EmojiPopularity.ordered)
    }

    func test_starterAliasesClampsToZero() {
        XCTAssertTrue(EmojiPopularity.starterAliases(limit: 0).isEmpty)
        XCTAssertTrue(EmojiPopularity.starterAliases(limit: -5).isEmpty)
    }
}
