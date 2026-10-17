import Foundation

/// File overview:
/// Turns a calendar event into a conversation-memory record, so memory can recall meetings by topic
/// ("the pilot review was moved to Thursday").
///
/// Mapping:
/// - Conversation: the event series (every occurrence of a weekly meeting is one conversation),
///   titled with the event's title.
/// - Sender "Calendar", never the user: an event is not something the user said, and its organizer
///   can be anyone who sent an invitation. The organizer is named in the text instead.
/// - Participants: the attendees' and organizer's addresses, the user left out, which is what the
///   "same people" scope of memory matches on.
/// - Timestamp: the event's start, so recency ranking favours what is coming up.
/// - A cancelled event stays a record, marked cancelled, so it replaces the one memory holds.
/// - Text: title, time, place and people as labelled lines, then the description without the
///   join-a-call boilerplate invitations carry (links, dial-in numbers, passcodes).
///
/// Pure, so it is tested without EventKit; `CalendarHistoryReader` feeds it snapshots.
nonisolated enum CalendarEventText {
    static let sender = "Calendar"
    static let maximumNotesCharacters = 1_500

    static func record(_ event: CalendarEventSnapshot, timeZone: TimeZone = .current) -> MemoryIngestRecord? {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let people = ([event.organizer].compactMap { $0 } + event.attendees).filter { !$0.isCurrentUser }
        let participants = Set(people.compactMap(\.email).filter { !$0.isEmpty }).sorted()
        return MemoryIngestRecord(
            sourceMessageID: event.id,
            conversationID: "event:" + event.seriesID,
            conversationTitle: title,
            sender: sender,
            isFromMe: false,
            timestamp: event.start,
            text: text(event, timeZone: timeZone),
            participants: participants,
            subject: nil
        )
    }

    static func text(_ event: CalendarEventSnapshot, timeZone: TimeZone = .current) -> String {
        var lines = ["Meeting: \(event.title.trimmingCharacters(in: .whitespacesAndNewlines))",
                     "When: \(when(event, timeZone: timeZone))"]
        // Kept, not dropped: the record replaces the meeting memory already holds, which would
        // otherwise go on saying it takes place.
        if event.isCancelled { lines.append("Status: cancelled") }
        if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty,
           !isCallLink(location) {
            lines.append("Where: \(location)")
        }
        if let organizer = event.organizer {
            lines.append("Organizer: \(organizer.isCurrentUser ? "you" : displayName(organizer))")
        }
        let others = event.attendees.filter { !$0.isCurrentUser && $0 != event.organizer }.map(displayName)
        if !others.isEmpty { lines.append("With: \(others.joined(separator: ", "))") }
        if let notes = event.notes.map(cleanedNotes), !notes.isEmpty { lines.append(notes) }
        return lines.joined(separator: "\n")
    }

    /// "Thu 9 Oct 2026, 14:00–15:00", or "Thu 9 Oct 2026, all day". English and 24-hour on purpose:
    /// the same text is stored whatever the Mac's locale, and both of the user's languages read it.
    static func when(_ event: CalendarEventSnapshot, timeZone: TimeZone = .current) -> String {
        let day = formatter("EEE d MMM yyyy", timeZone)
        if event.isAllDay { return "\(day.string(from: event.start)), all day" }
        let time = formatter("HH:mm", timeZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let end = calendar.isDate(event.start, inSameDayAs: event.end)
            ? time.string(from: event.end)
            : "\(day.string(from: event.end)) \(time.string(from: event.end))"
        return "\(day.string(from: event.start)), \(time.string(from: event.start))–\(end)"
    }

    static func displayName(_ person: CalendarEventSnapshot.Person) -> String {
        let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (person.email ?? "someone") : name
    }

    /// The description without the online-meeting block. Teams, Zoom and Webex append it after a
    /// rule of underscores or under a "Join …" heading; everything from there on is links, dial-in
    /// numbers and passcodes, which would only crowd out the agenda (and a passcode is a secret).
    static func cleanedNotes(_ notes: String) -> String {
        var kept: [String] = []
        for rawLine in notes.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lowered = line.lowercased()
            if line.hasPrefix("____") || line.hasPrefix("────") || callBlockOpeners.contains(where: { lowered.hasPrefix($0) }) {
                break
            }
            if line.isEmpty || isCallLink(line) { continue }
            kept.append(line)
        }
        let text = kept.joined(separator: "\n")
        return text.count > maximumNotesCharacters ? String(text.prefix(maximumNotesCharacters)) + "…" : text
    }

    private static let callBlockOpeners = [
        "microsoft teams meeting", "microsoft teams-besprechung", "microsoft teams toplantısı", "join the meeting",
        "join on your computer", "join zoom meeting", "join webex meeting", "join with google meet", "click here to join",
        "toplantıya katıl", "toplantıya katılın"
    ]

    private static func isCallLink(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("<http")
            || lowered.contains("teams.microsoft.com/") || lowered.contains("zoom.us/") || lowered.contains("meet.google.com/")
            || lowered.contains("webex.com/")
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}
