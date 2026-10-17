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
/// within 90. The first sync reads everything in the window.
///
/// A series with a change is read whole within the window and replaces what memory held for it
/// (`completeConversations`): a moved occurrence (its id carries its start) or one deleted from a
/// series that still exists leaves memory then. That needs memory's retention to bound the window
/// (`since`), since anything of the series before the window would go too; with retention off,
/// changes are only added. A whole series deleted from the calendar stays until retention removes
/// it (EventKit reports no deletions, and a series not in the window may simply be older).
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
        let window = events(start, now.addingTimeInterval(horizon))
        let wanted = window.filter { event in
            guard let last else { return true }
            let changed = (event.lastModified ?? .distantPast) > last.addingTimeInterval(-Self.modifiedLookBack)
            let enteredHorizon = event.start > last.addingTimeInterval(horizon)
            return changed || enteredHorizon
        }
        var complete = Set<String>()
        var read = wanted
        if since != nil {
            let series = Set(wanted.map(\.seriesID))
            read = window.filter { series.contains($0.seriesID) }
            complete = Set(read.compactMap { CalendarEventText.record($0)?.conversationID })
        }
        let records = read.compactMap { CalendarEventText.record($0) }
        // The cursor always moves to now: the next sync's "entered the horizon" starts from here.
        return MemoryReadPage(records: records, nextCursor: String(Int64(now.timeIntervalSince1970 * 1000)), hasMore: false,
                              completeConversations: complete)
    }
}
