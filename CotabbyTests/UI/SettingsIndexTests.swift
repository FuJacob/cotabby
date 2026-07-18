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

    func test_itemIdsAreUnique() {
        let ids = SettingsItem.allCases.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate SettingsItem ids break Identifiable lists")
    }

    func test_searchFindsRecentlyShippedSettings() {
        // Each pair pins one real query for a setting that previously shipped without an index
        // entry. If one of these fails, a rename or removal broke search for that setting.
        let expectations: [(query: String, item: SettingsItem)] = [
            ("ghost text size", .ghostTextSize),
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
        XCTAssertTrue(SettingsItem.results(for: "   ").isEmpty)
        XCTAssertTrue(SettingsItem.results(for: "").isEmpty)
    }
}
