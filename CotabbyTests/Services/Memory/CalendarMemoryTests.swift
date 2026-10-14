import Foundation
import XCTest
@testable import Cotabby

/// Pins the calendar side of memory: the memory record an event becomes (without call boilerplate,
/// without the user as a participant) and the reader's incremental window.
final class CalendarMemoryTests: XCTestCase {
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
        _ title: String, _ start: Date, _ end: Date, allDay: Bool = false, cancelled: Bool = false,
        attendees: [CalendarEventSnapshot.Person] = [], organizer: CalendarEventSnapshot.Person? = nil,
        notes: String? = nil, modified: Date? = nil, id: String? = nil
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            id: id ?? title, seriesID: id ?? title, title: title, start: start, end: end, isAllDay: allDay, location: nil,
            notes: notes, organizer: organizer, attendees: attendees, isCancelled: cancelled,
            lastModified: modified
        )
    }

    private let me = CalendarEventSnapshot.Person(name: "Alex", email: "alex@example.com", isCurrentUser: true)
    private let ayse = CalendarEventSnapshot.Person(name: "Ayşe Yılmaz", email: "ayse@client.example", isCurrentUser: false)

    func test_anEventBecomesARecordWithoutCallBoilerplate() throws {
        let notes = "Agenda: pilot scope and pricing\n\n________________\nMicrosoft Teams meeting\nJoin on your computer\nhttps://teams.microsoft.com/l/x\nPasscode: abc123"
        let record = try XCTUnwrap(CalendarEventText.record(
            event("Pilot review", date(8, 10), date(8, 11), attendees: [me, ayse], organizer: ayse, notes: notes, id: "E1"),
            timeZone: calendar.timeZone
        ))
        XCTAssertEqual(record.text, """
        Meeting: Pilot review
        When: Thu 8 Oct 2026, 10:00–11:00
        Organizer: Ayşe Yılmaz
        Agenda: pilot scope and pricing
        """)
        XCTAssertEqual(record.conversationID, "event:E1")
        XCTAssertEqual(record.participants, ["ayse@client.example"], "the user is not a participant")
        XCTAssertFalse(record.isFromMe, "an event is not something the user said")
        let cancelled = try XCTUnwrap(CalendarEventText.record(event("Sync", date(9, 9), date(9, 10), cancelled: true),
                                                               timeZone: calendar.timeZone))
        XCTAssertTrue(cancelled.text.contains("Status: cancelled"), "replaces the stored meeting instead of vanishing")
    }

    /// With retention bounding the window, a series with a change is read whole and marked
    /// complete, so a moved occurrence (whose id carries its old start) leaves memory.
    func test_aChangedSeriesIsReadWholeSoAMovedOccurrenceLeaves() throws {
        func occurrence(_ start: Date, modified: Date) -> CalendarEventSnapshot {
            CalendarEventSnapshot(
                id: "S@\(Int(start.timeIntervalSince1970))", seriesID: "S", title: "Weekly sync", start: start,
                end: start.addingTimeInterval(1_800), isAllDay: false, location: nil, notes: nil, organizer: nil,
                attendees: [], isCancelled: false, lastModified: modified
            )
        }
        let unchanged = occurrence(date(1, 9), modified: date(1))
        let moved = occurrence(date(8, 11), modified: now.addingTimeInterval(-60))
        let other = event("Lunch", date(2, 12), date(2, 13), modified: date(1))
        let events: [CalendarEventSnapshot] = [unchanged, moved, other]
        let reader = CalendarHistoryReader(events: { _, _ in events }, isAuthorized: { true }, now: { self.now })
        let cursor = String(Int64(now.addingTimeInterval(-86_400).timeIntervalSince1970 * 1000))
        let since: Date = now.addingTimeInterval(-365 * 86_400)

        let page = try reader.read(after: cursor, since: since, limit: 500)
        XCTAssertEqual(Set(page.records.map(\.sourceMessageID)), [unchanged.id, moved.id], "the whole series, not other events")
        XCTAssertEqual(page.completeConversations, ["event:S"])
        // Without retention the window does not hold the whole series: changes are only added.
        let unbounded = try reader.read(after: cursor, since: nil, limit: 500)
        XCTAssertEqual(unbounded.records.map(\.sourceMessageID), [moved.id])
        XCTAssertEqual(unbounded.completeConversations, [])
    }

    func test_theReaderReadsChangedEventsAndOnesEnteringTheHorizon() throws {
        let lastSync = now.addingTimeInterval(-86_400)
        let farStart: Date = lastSync.addingTimeInterval(91 * 86_400)
        let farEnd: Date = farStart.addingTimeInterval(3_600)
        let events: [CalendarEventSnapshot] = [
            event("Old unchanged", date(1, 10), date(1, 11), modified: date(1)),
            event("Moved", date(9, 10), date(9, 11), modified: now.addingTimeInterval(-600)),
            event("Far ahead", farStart, farEnd, modified: date(1)),
        ]
        let reader = CalendarHistoryReader(events: { _, _ in events }, isAuthorized: { true }, now: { self.now })
        let first = try reader.read(after: nil, since: nil, limit: 500)
        XCTAssertEqual(first.records.count, 3, "the first sync reads the whole window")
        let lastSyncMilliseconds: Int64 = Int64(lastSync.timeIntervalSince1970 * 1000)
        let next = try reader.read(after: String(lastSyncMilliseconds), since: nil, limit: 500)
        let titles: [String] = next.records.map(\.conversationTitle)
        XCTAssertEqual(titles, ["Moved", "Far ahead"])
        let nowMilliseconds: Int64 = Int64(now.timeIntervalSince1970 * 1000)
        XCTAssertEqual(next.nextCursor, String(nowMilliseconds))
        let denied = CalendarHistoryReader(events: { _, _ in events }, isAuthorized: { false }, now: { self.now })
        XCTAssertFalse(denied.readiness().isReady)
        XCTAssertTrue(try denied.read(after: nil, since: nil, limit: 10).records.isEmpty)
    }
}
