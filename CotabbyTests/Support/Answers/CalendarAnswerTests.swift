import Foundation
import XCTest
@testable import Cotabby

/// Pins the calendar side of answers: which questions are about the user's time and which days
/// they mean, and the free/busy facts an availability answer is drafted from (and that they reveal
/// nothing else). The memory record an event becomes is pinned by `CalendarMemoryTests`.
final class CalendarAnswerTests: XCTestCase {
    /// Fixed clock and calendar: Monday 5 October 2026, 10:30 in Istanbul.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return calendar
    }()
    private var now: Date { date(5, 10, 30) }

    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func event(
        _ title: String, _ start: Date, _ end: Date, allDay: Bool = false, busy: Bool = true,
        attendees: [CalendarEventSnapshot.Person] = []
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            id: title, seriesID: title, title: title, start: start, end: end, isAllDay: allDay, location: nil,
            notes: nil, organizer: nil, attendees: attendees, isCancelled: false,
            lastModified: nil, showsAsBusy: busy
        )
    }

    private let me = CalendarEventSnapshot.Person(name: "Alex", email: "alex@example.com", isCurrentUser: true)
    private let ayse = CalendarEventSnapshot.Person(name: "Ayşe Yılmaz", email: "ayse@client.example", isCurrentUser: false)

    // MARK: - Scheduling questions

    func test_availabilityQuestionsAreRecognisedAndOtherQuestionsAreNot() {
        for question in ["Are you free Thursday afternoon?", "Can we meet next week?", "When can we schedule the demo?",
                         "Yarın müsait misin?", "Perşembeye toplantı yapabilir miyiz, saat kaçta uygun?"] {
            XCTAssertNotNil(SchedulingQuestion.days(in: question, now: now, calendar: calendar), question)
        }
        for question in ["Did the meeting go well?", "Can you send the pilot numbers?", "Raporu gönderdin mi?"] {
            XCTAssertNil(SchedulingQuestion.days(in: question, now: now, calendar: calendar), question)
        }
    }

    func test_daysFollowTheWordsInBothLanguages() {
        let days: (String) -> [Date] = { question in SchedulingQuestion.days(in: question, now: self.now, calendar: self.calendar) ?? [] }
        XCTAssertEqual(days("Are you free tomorrow?"), [date(6)])
        XCTAssertEqual(days("Are you free Thursday?"), [date(8)])
        XCTAssertEqual(days("Perşembeye müsait misin?"), [date(8)], "a Turkish case ending on the day")
        XCTAssertEqual(days("Cumartesi müsait misin?"), [date(10)], "cumartesi is not cuma")
        XCTAssertEqual(days("Are you free next Thursday?"), [date(8), date(15)], "both readings of next")
        XCTAssertEqual(days("Can we meet next week?"), [date(12), date(13), date(14), date(15), date(16)])
        XCTAssertEqual(days("Are you free this week?"), [date(5), date(6), date(7), date(8), date(9)])
        XCTAssertEqual(days("Are you free on 9 Oct?"), [date(9)])
        XCTAssertEqual(days("9 Ekim'de müsait misin?"), [date(9)])
        XCTAssertEqual(days("Are you free 3.11?"), [date(3, month: 11)])
        XCTAssertEqual(days("When are you free?").count, SchedulingQuestion.defaultDays)
        XCTAssertNil(SchedulingQuestion.month(named: "decisions"), "a word starting like a month is not one")
    }

    // MARK: - Availability facts

    func test_freeTimeIsTheWorkdayAroundMeetingsFromNow() {
        let busy = [event("Standup", date(5, 9), date(5, 9, 15)), event("Review", date(5, 13), date(5, 14))]
        let gaps = AvailabilityFacts.freeGaps(day: date(5), busy: busy, now: now, calendar: calendar)
        XCTAssertEqual(gaps, [DateInterval(start: date(5, 10, 30), end: date(5, 13)), DateInterval(start: date(5, 14), end: date(5, 18))])
        XCTAssertEqual(AvailabilityFacts.freeGaps(day: date(5), busy: [], now: date(5, 19), calendar: calendar), [],
                       "after hours nothing is left, and nothing traps")
        XCTAssertEqual(AvailabilityFacts.freeGaps(day: date(6), busy: [event("OOO", date(6), date(7), allDay: true)],
                                                  now: now, calendar: calendar), [])
    }

    /// Only busy and free: who asks comes from the message, which its sender controls, so no event's
    /// title or people are ever in an availability fact.
    func test_availabilityFactsSayBusyAndFreeAndNothingElse() {
        let shared = event("Pilot review", date(8, 10), date(8, 11), attendees: [me, ayse])
        let private_ = event("Dentist", date(8, 14), date(8, 15))
        let free = event("Holiday", date(8), date(9), allDay: true, busy: false)
        let facts = AvailabilityFacts.facts(days: [date(8)], events: [shared, private_, free], language: .english,
                                            now: now, calendar: calendar)
        XCTAssertEqual(facts.first?.text,
                       "Thursday 8 October 2026: free 09:00–10:00, 11:00–14:00, 15:00–18:00; busy 10:00–11:00, 14:00–15:00")
        XCTAssertFalse(facts.contains { $0.text.contains("Pilot") || $0.text.contains("Dentist") || $0.text.contains("Ayşe") })
        let turkish = AvailabilityFacts.facts(days: [date(8)], events: [private_], language: .turkish, now: now, calendar: calendar)
        XCTAssertEqual(turkish.first?.text, "8 Ekim 2026 Perşembe: boş (müsait) 09:00–14:00, 15:00–18:00; dolu 14:00–15:00")
        XCTAssertEqual(AvailabilityFacts.language(of: "Perşembe öğleden sonra müsait misin?"), .turkish)
    }
}
