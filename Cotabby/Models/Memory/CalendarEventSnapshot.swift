import Foundation

/// File overview:
/// One calendar event occurrence as plain values, copied out of EventKit.
///
/// Why its own type: EventKit's `EKEvent` is a live, mutable object tied to the event store that made
/// it, cannot be built in a test, and is not `Sendable`. Copying the few fields memory uses into
/// a value lets the rules that turn events into memory records (`CalendarEventText`) be pure and
/// tested, and lets events cross from the
/// background reader to the main actor safely. Built by `EventKitCalendar`; nothing else talks to
/// EventKit.
nonisolated struct CalendarEventSnapshot: Equatable, Sendable {
    nonisolated struct Person: Equatable, Sendable {
        let name: String
        /// Lowercased mail address, when the calendar knows one.
        let email: String?
        /// EventKit's own judgement that this person is the Mac's user (matched to the account).
        let isCurrentUser: Bool
    }

    /// Stable across syncs for the same occurrence: the event's external identifier plus, for a
    /// repeating event, the occurrence's start.
    let id: String
    /// The same for every occurrence of a repeating event: its conversation in memory.
    let seriesID: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let notes: String?
    let organizer: Person?
    let attendees: [Person]
    let isCancelled: Bool
    /// When the event last changed, for incremental syncs.
    let lastModified: Date?
    /// Whether the event blocks the user's time (EventKit availability busy, tentative or out of
    /// office; a timed event the calendar gives no availability for counts too, an all-day one
    /// such as a holiday does not). Only answers' free/busy facts read it (`AvailabilityFacts`).
    var showsAsBusy = true
}
