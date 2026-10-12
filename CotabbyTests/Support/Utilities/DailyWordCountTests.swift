import XCTest
@testable import Cotabby

/// Locks the daily reset of the menu-bar word count: a count accumulates within one local day and
/// reads as zero on any other day.
final class DailyWordCountTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func test_dayStampIsZeroPaddedYearMonthDay() {
        XCTAssertEqual(DailyWordCount.dayStamp(for: date(2026, 3, 7), calendar: calendar), "2026-03-07")
    }

    func test_wordsAccumulateWithinOneDay() {
        let morning = DailyWordCount(dayStamp: "2026-03-07", count: 0)
            .adding(5, at: date(2026, 3, 7, hour: 9), calendar: calendar)
        let evening = morning.adding(3, at: date(2026, 3, 7, hour: 23), calendar: calendar)

        XCTAssertEqual(evening, DailyWordCount(dayStamp: "2026-03-07", count: 8))
    }

    func test_countResetsOnTheNextDay() {
        let yesterday = DailyWordCount(dayStamp: "2026-03-07", count: 412)

        XCTAssertEqual(
            yesterday.rolled(to: date(2026, 3, 8, hour: 0), calendar: calendar),
            DailyWordCount(dayStamp: "2026-03-08", count: 0)
        )
        XCTAssertEqual(
            yesterday.adding(2, at: date(2026, 3, 8), calendar: calendar),
            DailyWordCount(dayStamp: "2026-03-08", count: 2)
        )
    }

    func test_countResetsWhenTheDayMovesBackwards() {
        let count = DailyWordCount(dayStamp: "2026-03-07", count: 40)

        XCTAssertEqual(
            count.rolled(to: date(2026, 3, 6), calendar: calendar),
            DailyWordCount(dayStamp: "2026-03-06", count: 0)
        )
    }

    func test_sameDayRollKeepsTheCount() {
        let count = DailyWordCount(dayStamp: "2026-03-07", count: 40)

        XCTAssertEqual(count.rolled(to: date(2026, 3, 7, hour: 1), calendar: calendar), count)
    }

    func test_negativeValuesAreClampedToZero() {
        XCTAssertEqual(DailyWordCount(dayStamp: "2026-03-07", count: -4).count, 0)
        XCTAssertEqual(
            DailyWordCount(dayStamp: "2026-03-07", count: 3)
                .adding(-9, at: date(2026, 3, 7), calendar: calendar).count,
            3
        )
    }
}
