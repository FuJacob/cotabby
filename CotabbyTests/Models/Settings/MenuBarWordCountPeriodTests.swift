import XCTest
@testable import Cotabby

/// Locks which accepted-word total the menu-bar badge draws for each period, and the copy the
/// Settings picker shows for it.
final class MenuBarWordCountPeriodTests: XCTestCase {
    func test_allTimeShowsTheLifetimeTotal() {
        XCTAssertEqual(MenuBarWordCountPeriod.allTime.displayedCount(today: 12, allTime: 4_310), 4_310)
    }

    func test_todayShowsOnlyTodaysWords() {
        XCTAssertEqual(MenuBarWordCountPeriod.today.displayedCount(today: 12, allTime: 4_310), 12)
    }

    func test_displayLabels() {
        XCTAssertEqual(MenuBarWordCountPeriod.allTime.displayLabel, "All Time")
        XCTAssertEqual(MenuBarWordCountPeriod.today.displayLabel, "Today")
    }

    func test_rawValuesAreStableBecauseTheyArePersisted() {
        XCTAssertEqual(MenuBarWordCountPeriod.allTime.rawValue, "allTime")
        XCTAssertEqual(MenuBarWordCountPeriod.today.rawValue, "today")
    }
}
