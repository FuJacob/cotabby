import XCTest
@testable import Cotabby

/// The last-open Settings pane is persisted by raw value, so a renamed or merged pane would strand
/// a returning user on the fallback. These pin the mappings that keep them where they were.
@MainActor
final class SettingsCategoryRestorationTests: XCTestCase {
    func test_everyCurrentRawValueRestoresItsOwnPane() {
        for category in SettingsCategory.allCases {
            XCTAssertEqual(SettingsCategory.restored(fromStoredRawValue: category.rawValue), category)
        }
    }

    func test_retiredEngineRowsRestoreToEngineAndModel() {
        XCTAssertEqual(SettingsCategory.restored(fromStoredRawValue: "appleIntelligence"), .engineAndModel)
        XCTAssertEqual(SettingsCategory.restored(fromStoredRawValue: "openSource"), .engineAndModel)
    }

    func test_renamedAdvancedPaneRestoresToContext() {
        XCTAssertEqual(SettingsCategory.restored(fromStoredRawValue: "advanced"), .context)
    }

    func test_unknownRawValueFallsBackToGeneral() {
        XCTAssertEqual(SettingsCategory.restored(fromStoredRawValue: "noSuchPane"), .general)
        XCTAssertEqual(SettingsCategory.restored(fromStoredRawValue: ""), .general)
    }
}
