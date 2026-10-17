import Foundation
import NaturalLanguage

/// File overview:
/// Turns the user's calendar for the days a question asks about into facts an answer can be drafted
/// from: per day, when the user is busy and when they are free within working hours.
///
/// Privacy rule: only busy and free times, never what an event is or who is in it. Whoever asked
/// learns the time is taken, not that it is a doctor's appointment or another client's negotiation.
/// Revealing details to people who are in an event was considered and rejected: who is asking comes
/// from the message (a display name, a quoted "On … X wrote:" line), which its sender controls.
///
/// Facts are written in the question's language (English or Turkish), with day names in full, so
/// a draft that says "Perşembe" or "Thursday" finds that word in its facts and passes grounding.
/// Pure: `AnswerCoordinator` reads the events through `EventKitCalendar` and hands them in.
nonisolated enum AvailabilityFacts {
    enum Language: Equatable, Sendable {
        case english
        case turkish
    }

    /// The working day free time is offered within, in hours.
    static let workdayStartHour = 9
    static let workdayEndHour = 18
    /// Free gaps shorter than this are not offered (a quarter hour between meetings is not "free").
    static let minimumFreeMinutes = 30
    /// Where the facts say they came from, on the card and in the prompt.
    static let title = "Your calendar"

    /// The language to write facts in: Turkish when the question is, English otherwise.
    static func language(of question: String) -> Language {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .turkish]
        recognizer.processString(question)
        return recognizer.dominantLanguage == .turkish ? .turkish : .english
    }

    /// One fact per day, in order.
    static func facts(
        days: [Date], events: [CalendarEventSnapshot], language: Language, now: Date, calendar: Calendar = .current
    ) -> [AnswerPromptRenderer.Fact] {
        days.compactMap { day -> AnswerPromptRenderer.Fact? in
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            let busy = events
                .filter { $0.showsAsBusy && !$0.isCancelled && $0.start < dayEnd && $0.end > day }
                .sorted { $0.start < $1.start }
            let free = freeGaps(day: day, busy: busy, now: now, calendar: calendar)
            let text = line(day: day, busy: busy, free: free, language: language, calendar: calendar)
            return AnswerPromptRenderer.Fact(sender: title, isFromMe: true, conversationTitle: title,
                                             timestamp: day, text: text)
        }
    }

    /// Free stretches of the working day around the busy events; none for a day already over.
    static func freeGaps(day: Date, busy: [CalendarEventSnapshot], now: Date, calendar: Calendar) -> [DateInterval] {
        guard let open = calendar.date(bySettingHour: workdayStartHour, minute: 0, second: 0, of: day),
              let close = calendar.date(bySettingHour: workdayEndHour, minute: 0, second: 0, of: day) else { return [] }
        var cursor = max(open, now)
        // The working day is over (today, late): no free time left. Also keeps every interval below
        // well-formed, since `DateInterval` traps on an end before its start.
        guard cursor < close else { return [] }
        var gaps: [DateInterval] = []
        for event in busy where !event.isAllDay {
            if event.start > cursor { gaps.append(DateInterval(start: cursor, end: min(event.start, close))) }
            cursor = max(cursor, event.end)
            if cursor >= close { break }
        }
        if cursor < close { gaps.append(DateInterval(start: cursor, end: close)) }
        // An all-day busy event (out of office) takes the whole day.
        if busy.contains(where: \.isAllDay) { return [] }
        return gaps.filter { $0.duration >= Double(minimumFreeMinutes * 60) }
    }

    static func line(
        day: Date, busy: [CalendarEventSnapshot], free: [DateInterval], language: Language, calendar: Calendar
    ) -> String {
        let dayName = formatter(language == .turkish ? "d MMMM yyyy EEEE" : "EEEE d MMMM yyyy", language, calendar).string(from: day)
        let time = formatter("HH:mm", language, calendar)
        let busyParts = busy.map { event -> String in
            event.isAllDay
                ? (language == .turkish ? "tüm gün" : "all day")
                : "\(time.string(from: max(event.start, day)))–\(time.string(from: event.end))"
        }
        let freeParts = free.map { "\(time.string(from: $0.start))–\(time.string(from: $0.end))" }
        // Free time first: a prompt clips long facts, and the free slots are what the answer needs.
        switch language {
        case .english:
            let free = freeParts.isEmpty ? "no free time in working hours" : "free " + freeParts.joined(separator: ", ")
            let busy = busyParts.isEmpty ? "no meetings" : "busy " + busyParts.joined(separator: ", ")
            return "\(dayName): \(free); \(busy)"
        case .turkish:
            let free = freeParts.isEmpty ? "mesai saatlerinde boş zaman yok" : "boş (müsait) " + freeParts.joined(separator: ", ")
            let busy = busyParts.isEmpty ? "toplantı yok" : "dolu " + busyParts.joined(separator: ", ")
            return "\(dayName): \(free); \(busy)"
        }
    }

    private static func formatter(_ format: String, _ language: Language, _ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .turkish ? "tr_TR" : "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }
}
