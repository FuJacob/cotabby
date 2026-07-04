import XCTest
@testable import Cotabby

/// Locks the deterministic time math behind menu-bar pause choices. Keeping these tests pure makes
/// DST/calendar behavior reviewable without waiting for a real settings-model timer to fire.
final class SuggestionPauseModelsTests: XCTestCase {
    func test_minuteAndHourDurationsUseExpectedIntervals() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(
            SuggestionPauseDuration.fifteenMinutes.pauseState(from: now),
            .until(now.addingTimeInterval(15 * 60))
        )
        XCTAssertEqual(
            SuggestionPauseDuration.thirtyMinutes.pauseState(from: now),
            .until(now.addingTimeInterval(30 * 60))
        )
        XCTAssertEqual(
            SuggestionPauseDuration.oneHour.pauseState(from: now),
            .until(now.addingTimeInterval(60 * 60))
        )
    }

    func test_untilTomorrowUsesNextLocalCalendarMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 6, day: 28, hour: 22, minute: 30))
        )
        let expected = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 6, day: 29))
        )

        XCTAssertEqual(
            SuggestionPauseDuration.untilTomorrow.pauseState(from: now, calendar: calendar),
            .until(expected)
        )
    }

    func test_timedPauseBecomesInactiveAtExpiration() {
        let expiration = Date(timeIntervalSince1970: 2_000)
        let state = SuggestionPauseState.until(expiration)

        XCTAssertTrue(state.isActive(at: expiration.addingTimeInterval(-0.001)))
        XCTAssertFalse(state.isActive(at: expiration))
        XCTAssertNil(state.activeState(at: expiration.addingTimeInterval(1)))
        XCTAssertTrue(SuggestionPauseState.indefinitely.isActive(at: expiration))
    }
}
