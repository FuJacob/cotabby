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

    // MARK: - Scoring tiers (synthetic items)

    /// The catalog tests above prove product ordering; these pin the scoring model itself against
    /// minimal items, so a weight change is a visible, deliberate edit. Every token that hits the
    /// title adds the 15-point cohesion bonus, and a query equal to the whole title adds 40.
    func test_scoreTiersForSingleTokenQueries() {
        let ghost = StubItem(title: "Ghost")
        let ghostText = StubItem(title: "Ghost Text")
        let cases: [(query: String, item: StubItem, expected: Double)] = [
            ("ghost", ghost, 100 + 15 + 40),     // exact title
            ("gho", ghostText, 90 + 15),         // title prefix
            ("ghosts", ghost, 90 + 15),          // typed past the title: reverse prefix
            ("text", ghostText, 80 + 15),        // word prefix
            ("ost", ghost, 60 + 15),             // substring
            ("gst", ghost, 25 + 15),             // subsequence typo net
            ("transparency", StubItem(title: "Opacity", keywords: ["transparency"]), 70),
            ("emoji", StubItem(title: "Skin Tone", group: "Emoji"), 35),
            ("miss", StubItem(title: "Typo Guard", summary: "Hide when misspelled"), 30),
            ("spell", StubItem(title: "Typo Guard", summary: "Hide when misspelled"), 18),
            ("cafe", StubItem(title: "Café"), 100 + 15 + 40) // diacritics fold
        ]
        for testCase in cases {
            let matches = SettingsSearchRanker.matches(testCase.query, in: [testCase.item])
            XCTAssertEqual(matches.map(\.score), [testCase.expected], "query \(testCase.query)")
        }
    }

    /// Two-letter tokens skip the subsequence tier, which would otherwise match almost anything.
    func test_shortTokensDoNotFuzzyMatch() {
        XCTAssertTrue(SettingsSearchRanker.matches("gt", in: [StubItem(title: "Ghost")]).isEmpty)
    }

    /// Cohesion and the exact-title bonus separate rows whose per-token scores would otherwise
    /// tie or invert: all tokens in the title beat a split title/keyword hit, and the exact name
    /// beats a longer title containing the same words.
    func test_multiTokenBonusesOrderResults() {
        let splitHit = StubItem(title: "Ghost Text", keywords: ["size"])
        let titleHit = StubItem(title: "Ghost Text Size")
        XCTAssertEqual(
            SettingsSearchRanker.matches("ghost size", in: [splitHit, titleHit]).map(\.score),
            [90 + 80 + 15, 90 + 70] as [Double]
        )

        let longer = StubItem(title: "Accept Punctuation With Word")
        let exact = StubItem(title: "Accept Word")
        XCTAssertEqual(SettingsSearchRanker.rank("accept word", in: [longer, exact]), [exact, longer])
    }

    /// Equal scores keep declaration order so results do not shuffle between keystrokes.
    func test_tiesKeepDeclarationOrder() {
        let first = StubItem(title: "Ghost Color")
        let second = StubItem(title: "Ghost Size")
        XCTAssertEqual(SettingsSearchRanker.rank("ghost", in: [first, second]), [first, second])
        XCTAssertEqual(SettingsSearchRanker.rank("ghost", in: [second, first]), [second, first])
    }

    /// Only the first eight query tokens are scored, bounding work for a pathological paste; a
    /// ninth token that matches nothing therefore cannot fail the query.
    func test_queryIsCappedAtEightTokens() {
        let query = Array(repeating: "ghost", count: 8).joined(separator: " ") + " zzzz"
        XCTAssertEqual(
            SettingsSearchRanker.matches(query, in: [StubItem(title: "Ghost")]).map(\.score),
            [8 * 100 + 15] as [Double]
        )
    }
}

/// Minimal searchable row so scoring can be pinned without depending on the live catalog copy.
private struct StubItem: SettingsSearchable, Equatable {
    let searchTitle: String
    let searchKeywords: [String]
    let searchGroupLabel: String
    let searchSummary: String

    init(title: String, keywords: [String] = [], group: String = "", summary: String = "") {
        searchTitle = title
        searchKeywords = keywords
        searchGroupLabel = group
        searchSummary = summary
    }
}
