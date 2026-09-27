import XCTest
@testable import Cotabby

/// Locks the deterministic time math behind menu-bar pause choices. Keeping these tests pure makes
/// DST/calendar behavior reviewable without waiting for a real settings-model timer to fire.
final class SuggestionPauseModelsTests: XCTestCase {
    func test_menuLabels_arePinnedInMenuOrder() {
        XCTAssertEqual(
            SuggestionPauseDuration.allCases.map(\.menuLabel),
            [
                "Pause for 15 Minutes",
                "Pause for 30 Minutes",
                "Pause for 1 Hour",
                "Pause Until Tomorrow",
                "Pause Until I Turn It Back On"
            ]
        )
    }

    func test_minuteAndHourDurationsUseExpectedIntervals() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cases: [(duration: SuggestionPauseDuration, seconds: TimeInterval)] = [
            (.fifteenMinutes, 15 * 60),
            (.thirtyMinutes, 30 * 60),
            (.oneHour, 60 * 60)
        ]

        for testCase in cases {
            XCTAssertEqual(
                testCase.duration.pauseState(from: now),
                .until(now.addingTimeInterval(testCase.seconds)),
                "\(testCase.duration)"
            )
        }
        XCTAssertEqual(SuggestionPauseDuration.indefinitely.pauseState(from: now), .indefinitely)
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

        XCTAssertEqual(state.expirationDate, expiration)
        XCTAssertTrue(state.isActive(at: expiration.addingTimeInterval(-0.001)))
        XCTAssertFalse(state.isActive(at: expiration))
        XCTAssertNil(state.activeState(at: expiration.addingTimeInterval(1)))
    }

    func test_indefinitePauseIsAlwaysActiveAndHasNoExpiration() {
        let farFuture = Date.distantFuture

        XCTAssertNil(SuggestionPauseState.indefinitely.expirationDate)
        XCTAssertTrue(SuggestionPauseState.indefinitely.isActive(at: farFuture))
        XCTAssertEqual(SuggestionPauseState.indefinitely.activeState(at: farFuture), .indefinitely)
    }

    // MARK: - statusText

    func test_statusText_choosesCopyByPauseKind() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: Date()))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))
        let laterToday = now.addingTimeInterval(60 * 60)
        let inTwoDays = now.addingTimeInterval(2 * 24 * 60 * 60)

        XCTAssertEqual(SuggestionPauseState.indefinitely.statusText(at: now, calendar: calendar), "Paused until enabled")
        // Exactly next midnight reads as "tomorrow" rather than a clock time.
        XCTAssertEqual(
            SuggestionPauseState.until(tomorrow).statusText(at: now, calendar: calendar),
            "Paused until tomorrow"
        )
        // Same-day expirations show only the time; later days add the date.
        XCTAssertEqual(
            SuggestionPauseState.until(laterToday).statusText(at: now, calendar: calendar),
            "Paused until \(laterToday.formatted(date: .omitted, time: .shortened))"
        )
        XCTAssertEqual(
            SuggestionPauseState.until(inTwoDays).statusText(at: now, calendar: calendar),
            "Paused until \(inTwoDays.formatted(date: .abbreviated, time: .shortened))"
        )
    }

    func test_statusText_isNilOnceThePauseExpired() {
        let expiration = Date(timeIntervalSince1970: 2_000)

        XCTAssertNil(SuggestionPauseState.until(expiration).statusText(at: expiration))
    }

    // MARK: - Persistence shape

    func test_decodesThePersistedJSONShape() throws {
        // `cotabbySuggestionPauseState` stores the synthesized Codable form. Decoding literals pins
        // that shape, so a case rename cannot silently drop a user's pause across an update.
        let indefinite = try JSONDecoder().decode(SuggestionPauseState.self, from: Data(#"{"indefinitely":{}}"#.utf8))
        XCTAssertEqual(indefinite, .indefinitely)

        let timed = try JSONDecoder().decode(SuggestionPauseState.self, from: Data(#"{"until":{"_0":1000}}"#.utf8))
        XCTAssertEqual(timed, .until(Date(timeIntervalSinceReferenceDate: 1000)))
    }
}
