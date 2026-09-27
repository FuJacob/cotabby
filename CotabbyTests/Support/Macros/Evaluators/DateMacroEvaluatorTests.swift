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

    func test_dateStyleArguments() {
        let sut = makeEvaluator()
        XCTAssertEqual(sut.evaluate("today(iso)")?.insertionText, "2026-06-04")
        XCTAssertEqual(sut.evaluate("today(long)")?.insertionText, "June 4, 2026")
        XCTAssertEqual(sut.evaluate("today(short)")?.insertionText, "6/4/26")
        // An unrecognized argument falls back to the medium style rather than rejecting the macro.
        XCTAssertEqual(sut.evaluate("today(bogus)")?.insertionText, "Jun 4, 2026")
    }

    func test_styleArgumentAppliesToOffsetKeywords() {
        let sut = makeEvaluator()
        XCTAssertEqual(sut.evaluate("tomorrow(iso)")?.insertionText, "2026-06-05")
        XCTAssertEqual(sut.evaluate("+1d(iso)")?.insertionText, "2026-06-05")
    }

    func test_keywordsAreCaseInsensitiveAndHaveWordAliases() {
        let sut = makeEvaluator()
        XCTAssertEqual(sut.evaluate("TODAY")?.insertionText, "Jun 4, 2026")
        XCTAssertEqual(sut.evaluate("date")?.insertionText, "Jun 4, 2026")
        XCTAssertEqual(sut.evaluate("time(24h)")?.insertionText, "12:00")
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

    func test_weekdayMatchingToday_nextAndLastJumpAFullWeek() {
        // The clock is a Thursday: `next` and `last` are strictly after/before today.
        let sut = makeEvaluator()
        XCTAssertEqual(sut.evaluate("next-thu")?.insertionText, "Jun 11, 2026")
        XCTAssertEqual(sut.evaluate("last-thu")?.insertionText, "May 28, 2026")
    }

    func test_thisWeekday_looksForwardForEarlierWeekdays() {
        // `this-wed` on a Thursday is the coming Wednesday, not yesterday.
        XCTAssertEqual(makeEvaluator().evaluate("this-wed")?.insertionText, "Jun 10, 2026")
    }

    func test_fullWeekdayNames() {
        XCTAssertEqual(makeEvaluator().evaluate("next friday")?.insertionText, "Jun 5, 2026")
    }

    func test_unknownWeekdayName_returnsNil() {
        XCTAssertNil(makeEvaluator().evaluate("next-funday"))
    }

    func test_relativeOffsets() {
        let sut = makeEvaluator()
        XCTAssertEqual(sut.evaluate("+3d")?.insertionText, "Jun 7, 2026")
        XCTAssertEqual(sut.evaluate("+1w")?.insertionText, "Jun 11, 2026")
        XCTAssertEqual(sut.evaluate("-5d")?.insertionText, "May 30, 2026")
        XCTAssertEqual(sut.evaluate("+1mo")?.insertionText, "Jul 4, 2026")
        XCTAssertEqual(sut.evaluate("-1mo")?.insertionText, "May 4, 2026")
        XCTAssertEqual(sut.evaluate("+1y")?.insertionText, "Jun 4, 2027")
    }

    func test_malformedRelativeOffsets_returnNil() {
        let sut = makeEvaluator()
        for query in ["+d", "+3", "+3x", "3d"] {
            XCTAssertNil(sut.evaluate(query), query)
        }
    }

    func test_now24HourArgument() {
        XCTAssertEqual(makeEvaluator().evaluate("now(24h)")?.insertionText, "12:00")
    }

    func test_unknownKeyword_returnsNil() {
        XCTAssertNil(makeEvaluator().evaluate("someday"))
    }

    func test_shortFormAliases() {
        let sut = makeEvaluator()
        XCTAssertEqual(sut.evaluate("tdy")?.insertionText, "Jun 4, 2026")
        XCTAssertEqual(sut.evaluate("tmrw")?.insertionText, "Jun 5, 2026")
        XCTAssertEqual(sut.evaluate("yest")?.insertionText, "Jun 3, 2026")
        XCTAssertEqual(sut.evaluate("rn")?.insertionText, sut.evaluate("now")?.insertionText)
    }

    func test_weekdaySeparatorVariants() {
        let sut = makeEvaluator()
        XCTAssertEqual(sut.evaluate("next fri")?.insertionText, "Jun 5, 2026")
        XCTAssertEqual(sut.evaluate("nextfri")?.insertionText, "Jun 5, 2026")
        XCTAssertEqual(sut.evaluate("next_fri")?.insertionText, "Jun 5, 2026")
    }

    func test_spelledOutRelativeUnits() {
        let sut = makeEvaluator()
        XCTAssertEqual(sut.evaluate("+1week")?.insertionText, "Jun 11, 2026")
        XCTAssertEqual(sut.evaluate("+2days")?.insertionText, "Jun 6, 2026")
    }

    func test_noonAndMidnight_with24HourArgument() {
        let sut = makeEvaluator()
        XCTAssertEqual(sut.evaluate("noon(24h)")?.insertionText, "12:00")
        XCTAssertEqual(sut.evaluate("midnight(24h)")?.insertionText, "00:00")
    }

    func test_noon_defaultsToTwelveHourClock() {
        // en_US short time style renders an AM/PM marker. The separator between the digits and the
        // marker varies across ICU versions (regular vs narrow no-break space), so only the stable
        // leading digits are pinned here.
        let result = makeEvaluator().evaluate("noon")?.insertionText
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.hasPrefix("12:00") ?? false, "Expected 12-hour rendering, got \(result ?? "nil")")
        XCTAssertNotEqual(result, "12:00", "Without (24h) the locale's AM/PM marker must be present")
    }

    func test_middayAlias_resolvesToNoon() {
        let sut = makeEvaluator()
        XCTAssertEqual(sut.evaluate("midday(24h)")?.insertionText, sut.evaluate("noon(24h)")?.insertionText)
    }

    func test_datetime_combinesMediumDateWithShortTime() {
        // The date/time joiner ("at") and the AM/PM separator are ICU details, so assert the two
        // halves rather than the full literal string.
        let result = makeEvaluator().evaluate("datetime")?.insertionText
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("Jun 4, 2026") ?? false, "Expected medium date in \(result ?? "nil")")
        XCTAssertTrue(result?.contains("12:00") ?? false, "Expected short time in \(result ?? "nil")")
    }

    func test_dtAlias_resolvesToDatetime() {
        let sut = makeEvaluator()
        XCTAssertEqual(sut.evaluate("dt")?.insertionText, sut.evaluate("datetime")?.insertionText)
    }

    func test_unknownWeekdayPrefix_returnsNil() {
        // "blah-fri" carries a valid weekday token but no recognized this/next/last prefix, so the
        // weekday resolver must decline instead of guessing a direction.
        XCTAssertNil(makeEvaluator().evaluate("blah-fri"))
    }
}
