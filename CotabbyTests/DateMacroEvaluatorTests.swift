import XCTest
@testable import Cotabby

/// Tests for the pure date macro evaluator. The clock is pinned to Thursday 2026-06-04 12:00 UTC and
/// a UTC gregorian calendar with the en_US locale, so every assertion is deterministic.
final class DateMacroEvaluatorTests: XCTestCase {
    private func makeEvaluator() -> DateMacroEvaluator {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 4, hour: 12, minute: 0))!
        return DateMacroEvaluator(now: { now }, calendar: calendar, locale: locale)
    }

    func test_today_mediumLocaleFormat() {
        XCTAssertEqual(makeEvaluator().evaluate("today")?.insertionText, "Jun 4, 2026")
    }

    func test_todayIsoArgument() {
        XCTAssertEqual(makeEvaluator().evaluate("today(iso)")?.insertionText, "2026-06-04")
    }

    func test_tomorrowAndYesterday() {
        let sut = makeEvaluator()
        XCTAssertEqual(sut.evaluate("tomorrow")?.insertionText, "Jun 5, 2026")
        XCTAssertEqual(sut.evaluate("yesterday")?.insertionText, "Jun 3, 2026")
    }

    func test_nextFriday_fromThursday() {
        XCTAssertEqual(makeEvaluator().evaluate("next-fri")?.insertionText, "Jun 5, 2026")
    }

    func test_thisWeekday_includesToday() {
        XCTAssertEqual(makeEvaluator().evaluate("this-thu")?.insertionText, "Jun 4, 2026")
    }

    func test_lastFriday_fromThursday() {
        XCTAssertEqual(makeEvaluator().evaluate("last-fri")?.insertionText, "May 29, 2026")
    }

    func test_relativeOffsets() {
        let sut = makeEvaluator()
        XCTAssertEqual(sut.evaluate("+3d")?.insertionText, "Jun 7, 2026")
        XCTAssertEqual(sut.evaluate("+1w")?.insertionText, "Jun 11, 2026")
        XCTAssertEqual(sut.evaluate("-5d")?.insertionText, "May 30, 2026")
    }

    func test_now24HourArgument() {
        XCTAssertEqual(makeEvaluator().evaluate("now(24h)")?.insertionText, "12:00")
    }

    func test_unknownKeyword_returnsNil() {
        XCTAssertNil(makeEvaluator().evaluate("someday"))
    }
}
