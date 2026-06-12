import XCTest
@testable import Cotabby

/// Pins the relevance behavior of Settings search. The ranker is the difference between "search
/// finds something" and "search finds the right thing first", so these tests encode the ordering
/// promises the UI relies on: direct title hits beat synonym hits, multi-word queries converge on
/// the one row that matches every word, and near-miss typos still land.
final class SettingsSearchRankerTests: XCTestCase {
    func test_exactTitleOutranksKeywordMatch() {
        let results = SettingsSearchRanker.rank("languages", in: SettingsItem.allCases)
        XCTAssertEqual(results.first, .languages,
                       "a query that IS a row's title should put that row first")
        XCTAssertTrue(results.contains(.spellingDictionaries),
                      "keyword matches should still appear below the direct hit")
    }

    func test_titlePrefixOutranksKeywordOnlyMatches() {
        let results = SettingsSearchRanker.rank("ghost", in: SettingsItem.allCases)
        let topThree = Array(results.prefix(3))
        XCTAssertEqual(
            Set(topThree),
            Set([.ghostTextColor, .ghostTextOpacity, .ghostTextSize]),
            "rows titled Ghost Text … should outrank rows that only mention ghost in keywords"
        )
    }

    func test_multiWordQueryConvergesOnTheRowMatchingEveryWord() {
        XCTAssertEqual(
            SettingsSearchRanker.rank("ghost size", in: SettingsItem.allCases).first,
            .ghostTextSize
        )
        XCTAssertEqual(
            SettingsSearchRanker.rank("emoji history", in: SettingsItem.allCases).first,
            .emojiHistory
        )
    }

    func test_multiWordQueryRequiresEveryWordToMatch() {
        let results = SettingsSearchRanker.rank("ghost spaceship", in: SettingsItem.allCases)
        XCTAssertTrue(results.isEmpty,
                      "a token that matches nothing should fail the whole query, not be ignored")
    }

    func test_subsequenceMatchingCatchesNearMissTypos() {
        XCTAssertTrue(
            SettingsSearchRanker.rank("batery", in: SettingsItem.allCases).contains(.batteryModel),
            "a dropped letter should still find the row via subsequence matching"
        )
    }

    func test_paneLabelQuerySurfacesThePanesItems() {
        let results = SettingsSearchRanker.rank("emoji", in: SettingsItem.allCases)
        for item in [SettingsItem.emojiPicker, .emojiSkinTone, .emojiPeopleStyle, .emojiHistory] {
            XCTAssertTrue(results.contains(item), "pane-name query should include \(item)")
        }
    }

    func test_summaryTextIsSearchable() {
        XCTAssertTrue(
            SettingsSearchRanker.rank("misspelled", in: SettingsItem.allCases)
                .contains(.hideSuggestionsOnTypo),
            "summary phrasing should be matchable even when title and keywords miss"
        )
    }

    func test_blankAndWhitespaceQueriesReturnNothing() {
        XCTAssertTrue(SettingsSearchRanker.rank("", in: SettingsItem.allCases).isEmpty)
        XCTAssertTrue(SettingsSearchRanker.rank("   ", in: SettingsItem.allCases).isEmpty)
    }

    func test_everyItemIsTheTopResultForItsOwnTitle() {
        // The strongest find-anything guarantee: typing a row's exact title always puts that row
        // first. If a new item's title collides with existing keywords hard enough to lose, this
        // fails and the title or weights need attention.
        for item in SettingsItem.allCases {
            let results = SettingsSearchRanker.rank(item.title, in: SettingsItem.allCases)
            XCTAssertEqual(results.first, item,
                           "\"\(item.title)\" should rank \(item) first, got \(String(describing: results.first))")
        }
    }

    func test_diacriticsFoldIntoPlainLetters() {
        XCTAssertTrue(
            SettingsSearchRanker.rank("émoji", in: SettingsItem.allCases).contains(.emojiPicker),
            "accented input should match unaccented catalog text"
        )
    }
}
