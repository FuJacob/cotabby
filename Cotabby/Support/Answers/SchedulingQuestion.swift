import Foundation

/// File overview:
/// Recognises a question about the user's time ("are you free Thursday?", "yarın müsait misin?",
/// "when can we meet next week?") and works out which days it is about.
///
/// Why separate from `QuestionDetector`: that one decides *whether* a message asks something; this
/// one decides whether the answer lives in the calendar, and for which days, so `AnswerCoordinator`
/// can read just those days from EventKit (`AvailabilityFacts` then turns them into facts).
///
/// It covers English and Turkish (with Turkish case endings on day names: "perşembeye", "cuma
/// günü"). A reference that can mean two days covers both: "next Thursday" said on a Monday is this
/// week's or next week's Thursday depending on the speaker, so the answer gets both and can say
/// which it means. With no day named, today and the next four days are used. Pure; used by
/// `AnswerCoordinator`.
nonisolated enum SchedulingQuestion {
    /// The most days one question can cover, so a vague question never reads a whole season.
    static let maximumDays = 14
    /// Days covered when the question names none: today and the next four.
    static let defaultDays = 5

    /// The start of each day the question is about, in order; nil when it is not about the user's time.
    static func days(in question: String, now: Date, calendar: Calendar = .current) -> [Date]? {
        let text = question.lowercased()
        guard isAboutTime(text) else { return nil }
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        var offsets = namedDayOffsets(text, weekday: weekday)
        // A whole week only when no single day is named ("next week" vs "Thursday next week").
        if offsets.isEmpty { offsets = weekOffsets(text, weekday: weekday) }
        let day: (Int) -> Date? = { offset in calendar.date(byAdding: .day, value: offset, to: today) }
        var days = Set(offsets.compactMap(day))
        days.formUnion(explicitDates(in: text, today: today, calendar: calendar))
        if days.isEmpty {
            days = Set((0..<defaultDays).compactMap(day))
        }
        let ordered = days.filter { $0 >= today }.sorted()
        return Array(ordered.prefix(maximumDays))
    }

    /// Days the question names relative to today ("tomorrow", "bugün") or by weekday, as offsets
    /// from today (`weekday` is today's, Sunday = 1).
    private static func namedDayOffsets(_ text: String, weekday current: Int) -> Set<Int> {
        var offsets = Set<Int>()
        if contains(text, ["day after tomorrow", "öbür gün", "yarından sonra"]) {
            offsets.insert(2)
        } else if contains(text, ["tomorrow", "yarın"]) {
            offsets.insert(1)
        }
        if contains(text, ["today", "bugün", "this afternoon", "this evening", "bu akşam", "öğleden sonra"]) { offsets.insert(0) }

        let saysNext = contains(text, ["next ", "gelecek ", "haftaya", "önümüzdeki "])
        for (weekday, names) in weekdayNames where names.contains(where: { containsWord(text, startingWith: $0) }) {
            // Days until the next such weekday (today counts: "Thursday" said on a Thursday morning).
            let offset = (weekday - current + 7) % 7
            offsets.insert(offset)
            if saysNext { offsets.insert(offset + 7) }
        }
        return offsets
    }

    /// A week named as a whole: next week's working days, or what is left of this one up to Friday.
    private static func weekOffsets(_ text: String, weekday current: Int) -> Set<Int> {
        if contains(text, ["next week", "gelecek hafta", "haftaya", "önümüzdeki hafta"]) {
            let toMonday = (9 - current) % 7 == 0 ? 7 : (9 - current) % 7
            return Set(toMonday..<(toMonday + 5))
        }
        if contains(text, ["this week", "bu hafta"]) {
            return Set(0...max(0, 6 - current))
        }
        return []
    }

    /// Whether the question is about when the user can do something. An availability word is enough;
    /// a meeting word needs a time word with it ("did the meeting go well?" is not about the calendar).
    static func isAboutTime(_ text: String) -> Bool {
        if contains(text, availabilityPhrases) { return true }
        let meeting = contains(text, meetingWords)
        let time = contains(text, timeWords) || weekdayNames.contains { $0.names.contains { containsWord(text, startingWith: $0) } }
            || !explicitDates(in: text, today: .distantPast, calendar: Calendar(identifier: .gregorian)).isEmpty
        return meeting && time
    }

    // MARK: - Vocabulary

    private static let availabilityPhrases = [
        "are you free", "are you available", "you free ", "you available", "your availability", "availability",
        "when can we", "when could we", "when are you free", "when works", "what time works", "which time works",
        "does that work for you", "would that work", "a good time", "time slot", "free slot", "are you around",
        "can we meet", "could we meet", "can we talk", "could we talk", "can we schedule", "reschedule",
        "müsait misin", "müsait misiniz", "müsait mi", "müsaitsen", "müsaitseniz", "müsaitlik", "uygun musun",
        "uygun musunuz", "uygun mu", "uygunsan", "uygunsanız", "boş musun", "boş musunuz", "vaktin var", "vaktiniz var",
        "zamanın var", "zamanınız var", "ne zaman müsait", "ne zaman uygun", "görüşebilir miyiz", "görüşelim mi",
        "konuşabilir miyiz", "toplanabilir miyiz"
    ]

    private static let meetingWords = [
        "meet", "meeting", "call", "sync", "catch up", "demo", "review", "workshop", "session", "appointment",
        "toplantı", "görüşme", "görüşelim", "konuşalım", "randevu", "sunum", "demo"
    ]

    private static let timeWords = [
        "when", "what time", "which day", "today", "tomorrow", "this week", "next week", "o'clock", " am", " pm",
        "ne zaman", "saat kaç", "saat kaçta", "hangi gün", "bugün", "yarın", "bu hafta", "gelecek hafta", "haftaya"
    ]

    /// Calendar weekday numbers (Sunday = 1) with their English and Turkish names. Longer names come
    /// first where one starts with another ("cumartesi" before "cuma", "pazartesi" before "pazar").
    static let weekdayNames: [(weekday: Int, names: [String])] = [
        (2, ["monday", "pazartesi"]), (3, ["tuesday", "salı"]), (4, ["wednesday", "çarşamba"]),
        (5, ["thursday", "perşembe"]), (6, ["friday", "cuma"]), (7, ["saturday", "cumartesi"]),
        (1, ["sunday", "pazar"])
    ]

    private static func contains(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { text.contains($0) }
    }

    /// Whether a word of `text` starts with `stem` (Turkish endings: "perşembeye", "cumaya"), without
    /// a longer day name that shares the stem ("cumartesi" is not "cuma", "pazartesi" not "pazar").
    static func containsWord(_ text: String, startingWith stem: String) -> Bool {
        let longer = ["cuma": "cumartesi", "pazar": "pazartesi"][stem]
        return text.split(whereSeparator: { !$0.isLetter }).contains { word in
            word.hasPrefix(stem) && !(longer.map { word.hasPrefix($0) } ?? false)
        }
    }

    // MARK: - Explicit dates

    private static let englishMonths = ["january", "february", "march", "april", "may", "june", "july", "august",
                                        "september", "october", "november", "december"]
    private static let turkishMonths = ["ocak", "şubat", "mart", "nisan", "mayıs", "haziran", "temmuz", "ağustos",
                                        "eylül", "ekim", "kasım", "aralık"]

    /// The month a word names: an English name or its abbreviation ("oct", "sept"), or a Turkish
    /// name with any case ending ("ekimde"). "decisions" names no month.
    static func month(named word: String) -> Int? {
        if word.count >= 3, let index = englishMonths.firstIndex(where: { $0.hasPrefix(word) }) { return index + 1 }
        if let index = turkishMonths.firstIndex(where: { word.hasPrefix($0) }) { return index + 1 }
        return nil
    }

    /// "9.10", "09/10" (day first, as both languages write it), "9 oct" / "9 ekim", and "oct 9". Each
    /// form is its own scan: in one alternation, "free 3" (word, number) would use up the "3" of "3.11".
    private static let numericDate = try? NSRegularExpression(pattern: #"\b(\d{1,2})[./](\d{1,2})\b"#)
    private static let dayThenMonth = try? NSRegularExpression(pattern: #"\b(\d{1,2})\s+([a-zşğüöçı]{3,})"#)
    private static let monthThenDay = try? NSRegularExpression(pattern: #"\b([a-z]{3,})\s+(\d{1,2})\b"#)

    static func explicitDates(in text: String, today: Date, calendar: Calendar) -> [Date] {
        let range = NSRange(text.startIndex..., in: text)
        func groups(_ match: NSTextCheckingResult) -> (String, String)? {
            guard let first = Range(match.range(at: 1), in: text), let second = Range(match.range(at: 2), in: text) else { return nil }
            return (String(text[first]), String(text[second]))
        }
        var pairs: [(day: Int?, month: Int?)] = []
        for match in numericDate?.matches(in: text, range: range) ?? [] {
            if let (day, month) = groups(match) { pairs.append((Int(day), Int(month))) }
        }
        for match in dayThenMonth?.matches(in: text, range: range) ?? [] {
            if let (day, name) = groups(match) { pairs.append((Int(day), month(named: name))) }
        }
        for match in monthThenDay?.matches(in: text, range: range) ?? [] {
            if let (name, day) = groups(match) { pairs.append((Int(day), month(named: name))) }
        }
        let year = calendar.component(.year, from: today)
        var dates: [Date] = []
        for pair in pairs {
            guard let day = pair.day, let month = pair.month, (1...31).contains(day), (1...12).contains(month) else { continue }
            // The next such date: this year's, or next year's once this year's has passed.
            for candidateYear in [year, year + 1] {
                if let date = calendar.date(from: DateComponents(year: candidateYear, month: month, day: day)), date >= today {
                    dates.append(date)
                    break
                }
            }
        }
        return dates
    }
}
