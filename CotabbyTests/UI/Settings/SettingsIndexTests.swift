import XCTest
@testable import Cotabby

/// Pins the hygiene rules of the Settings search index. The index drifts silently when a new
/// setting ships without an entry (it simply never appears in search), so these tests make the
/// cheap invariants loud: every item must carry a non-empty title, symbol, and keyword set, and
/// the queries users actually type for recently shipped settings must land on them.
final class SettingsIndexTests: XCTestCase {
    func test_everyItemHasTitleSymbolKeywordsAndSummary() {
        for item in SettingsItem.allCases {
            XCTAssertFalse(item.title.isEmpty, "\(item) needs a title")
            XCTAssertFalse(item.systemImage.isEmpty, "\(item) needs an SF Symbol")
            XCTAssertFalse(item.keywords.isEmpty, "\(item) needs search keywords")
            XCTAssertFalse(item.summary.isEmpty, "\(item) needs a one-line summary for search results")
        }
    }

    func test_sidebarGroupsCoverEveryCategoryExactlyOnce() {
        // The sidebar renders from `sidebarGroups`, not `allCases`, so a category missing from the
        // groups would silently disappear from the window. Order is pinned too: the flattened
        // groups must read in the same top-down sequence the enum declares.
        let flattened = SettingsCategory.sidebarGroups.flatMap { $0 }
        XCTAssertEqual(flattened, SettingsCategory.allCases,
                       "sidebar groups must list every category exactly once, in declaration order")
    }

    func test_everyPaneExceptHomeIsReachableFromSearch() {
        // Home is the search surface itself; every other pane must own at least one indexed row,
        // or search can never land on it.
        let searchableCategories = Set(SettingsItem.allCases.map(\.category))
        for category in SettingsCategory.allCases where category != .home {
            XCTAssertTrue(searchableCategories.contains(category), "\(category) has no SettingsItem entries")
        }
        XCTAssertFalse(searchableCategories.contains(.home), "Home hosts search and should not index rows")
    }

    func test_typingAnItemsExactTitleRanksThatItemFirst() {
        // The ranker's exact-title bonus exists so a row's own name always wins. Running it over the
        // real catalog catches a new title that collides with (or is shadowed by) another item.
        for item in SettingsItem.allCases {
            XCTAssertEqual(
                SettingsItem.results(for: item.title).first,
                item,
                "searching \"\(item.title)\" should rank \(item) first"
            )
        }
    }

    func test_searchFindsRecentlyShippedSettings() {
        // Each pair pins one real query for a setting that previously shipped without an index
        // entry. If one of these fails, a rename or removal broke search for that setting.
        let expectations: [(query: String, item: SettingsItem)] = [
            ("ghost text size", .ghostTextSize),
            ("predict ahead", .predictAheadWhileTyping),
            ("background", .predictAheadWhileTyping),
            ("mid word", .suggestWithinWords),
            ("word boundary", .suggestWithinWords),
            ("next words", .showFollowingWords),
            ("one word", .showFollowingWords),
            ("smallest ghost text", .ghostTextSizeFloor),
            ("largest ghost text", .ghostTextSizeCeiling),
            ("terminal", .suggestInIntegratedTerminals),
            ("vscode", .suggestInIntegratedTerminals),
            ("typo", .automaticallyFixTypos),
            ("model status", .modelStatus),
            ("battery", .batteryModel),
            ("plugged", .pluggedInModel)
        ]
        for expectation in expectations {
            XCTAssertTrue(
                SettingsItem.results(for: expectation.query).contains(expectation.item),
                "query \"\(expectation.query)\" should surface \(expectation.item)"
            )
        }
    }

    func test_blankQueryReturnsNothing() {
        for query in ["", "   ", "\n\t"] {
            XCTAssertEqual(SettingsItem.results(for: query), [], "query \(query.debugDescription)")
        }
    }

    #if DEBUG
    func test_debugOverlaySettingIsSearchableInDevelopmentBuilds() {
        XCTAssertTrue(SettingsItem.results(for: "debug overlays").contains(.developmentDebugOverlays))
        XCTAssertEqual(SettingsItem.developmentDebugOverlays.category, .general)
    }
    #endif
}
