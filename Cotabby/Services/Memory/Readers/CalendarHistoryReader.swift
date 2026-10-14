import Foundation

/// File overview:
/// Reads calendar events into conversation memory, through EventKit (`EventKitCalendar`), from every
/// calendar the Calendar app shows.
///
/// The window is memory's retention behind and `horizonDays` ahead: upcoming meetings are the ones
/// most often written about ("the review is on Thursday at 14:00"). Each event occurrence becomes a
/// record through `CalendarEventText`; a changed event (moved, renamed, cancelled) is the same record
/// again with new text, which the store's upsert replaces.
///
/// Cursor: the time of the last sync. A sync reads the events that changed since then (EventKit's
/// last-modified date, with a small look-back) plus the events that entered the horizon since then,
/// which otherwise would never be read: a meeting 91 days out does not change on the day it comes
/// within 90. The first sync reads everything in the window. An event deleted from the calendar
/// stays in memory until retention removes it (EventKit reports no deletions).
nonisolated struct CalendarHistoryReader: MemoryHistoryReading {
    static let id = "calendar"
    let sourceID = Self.id
    static let horizonDays = 90
    static let defaultLookBackDays = 365
    static let modifiedLookBack: TimeInterval = 3_600

    /// The events source; EventKit in the app, fixed snapshots in tests.
    let events: @Sendable (Date, Date) -> [CalendarEventSnapshot]
    let isAuthorized: @Sendable () -> Bool
    let now: @Sendable () -> Date

    init(
        events: @escaping @Sendable (Date, Date) -> [CalendarEventSnapshot] = { EventKitCalendar.events(from: $0, to: $1) },
        isAuthorized: @escaping @Sendable () -> Bool = { EventKitCalendar.isAuthorized },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.events = events
        self.isAuthorized = isAuthorized
        self.now = now
    }

    func readiness() -> MemorySourceReadiness {
        isAuthorized() ? .ready : .failed("Allow Cotabby to read your calendars (Allow Calendar Access below).")
    }

    func read(after cursor: String?, since: Date?, limit: Int) throws -> MemoryReadPage {
        guard isAuthorized() else { return MemoryReadPage(records: [], nextCursor: nil, hasMore: false) }
        let now = now()
        let horizon = TimeInterval(Self.horizonDays * 86_400)
        let start = since ?? now.addingTimeInterval(-TimeInterval(Self.defaultLookBackDays * 86_400))
        let last = cursor.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        let records = events(start, now.addingTimeInterval(horizon)).filter { event in
            guard let last else { return true }
            let changed = (event.lastModified ?? .distantPast) > last.addingTimeInterval(-Self.modifiedLookBack)
            let enteredHorizon = event.start > last.addingTimeInterval(horizon)
            return changed || enteredHorizon
        }.compactMap { CalendarEventText.record($0) }
        // The cursor always moves to now: the next sync's "entered the horizon" starts from here.
        return MemoryReadPage(records: records, nextCursor: String(Int64(now.timeIntervalSince1970 * 1000)), hasMore: false)
    }
}
