import EventKit
import Foundation

/// File overview:
/// The one place Cotabby talks to EventKit: Calendar permission, and events copied out as
/// `CalendarEventSnapshot` values.
///
/// EventKit sees every calendar the Calendar app has (iCloud, Google, Exchange and CalDAV accounts
/// added in System Settings), which is how a work calendar reaches Cotabby without reading
/// New Outlook's files. Access is macOS's "Full Access" to Calendars, asked for once from the memory
/// settings (`NSCalendarsFullAccessUsageDescription`); the hardened runtime also needs the app's
/// Calendars entitlement (`Cotabby.entitlements`).
///
/// Threading: an `EKEventStore` is created per read, on whatever background task reads, and never
/// shared, so no store crosses threads. Creating one is cheap next to the sync that uses it.
/// Snapshots are values and cross freely. Used by `CalendarHistoryReader`, the Memory pane's
/// "Allow Calendar Access" button, and `AnswerCoordinator` (free/busy for availability answers).
nonisolated enum EventKitCalendar {
    /// Whether Cotabby may read events.
    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Whether macOS has not asked the user yet (the request shows its dialog only then; after a
    /// "Don't Allow" only System Settings can change it).
    static var canAsk: Bool {
        EKEventStore.authorizationStatus(for: .event) == .notDetermined
    }

    /// Asks macOS for full access to events. True when granted.
    static func requestAccess() async -> Bool {
        (try? await EKEventStore().requestFullAccessToEvents()) ?? false
    }

    /// Every event occurrence overlapping `start..<end`, in every calendar but the contacts'
    /// birthdays (people's data, not the user's time). Empty without access.
    static func events(from start: Date, to end: Date) -> [CalendarEventSnapshot] {
        guard isAuthorized, start < end else { return [] }
        let store = EKEventStore()
        let calendars = store.calendars(for: .event).filter { $0.type != .birthday }
        guard !calendars.isEmpty else { return [] }
        // EventKit expands repeating events into occurrences itself; a predicate spans at most four
        // years, far more than memory's window.
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).map(snapshot)
    }

    static func snapshot(_ event: EKEvent) -> CalendarEventSnapshot {
        let series = event.calendarItemExternalIdentifier ?? event.calendarItemIdentifier
        // A repeating event's occurrences share the series id; each gets its start appended so every
        // occurrence is its own record.
        let id = event.hasRecurrenceRules ? "\(series)@\(Int(event.startDate.timeIntervalSince1970))" : series
        var busy: Bool
        switch event.availability {
        case .free: busy = false
        case .notSupported: busy = !event.isAllDay
        default: busy = true  // .busy, .tentative, .unavailable (out of office)
        }
        // An invitation the user declined does not take their time.
        if event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined { busy = false }
        return CalendarEventSnapshot(
            id: id, seriesID: series, title: event.title ?? "", start: event.startDate, end: event.endDate,
            isAllDay: event.isAllDay, location: event.location, notes: event.notes,
            organizer: event.organizer.map(person),
            attendees: (event.attendees ?? []).map(person), isCancelled: event.status == .canceled,
            lastModified: event.lastModifiedDate, showsAsBusy: busy
        )
    }

    private static func person(_ participant: EKParticipant) -> CalendarEventSnapshot.Person {
        // A participant's URL is usually "mailto:address"; anything else carries no address.
        let url = participant.url.absoluteString
        let email = url.lowercased().hasPrefix("mailto:") ? String(url.dropFirst(7)).lowercased().removingPercentEncoding : nil
        return CalendarEventSnapshot.Person(name: participant.name ?? "", email: email, isCurrentUser: participant.isCurrentUser)
    }
}
