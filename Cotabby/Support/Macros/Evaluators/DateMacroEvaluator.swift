import Foundation

/// File overview:
/// Locale-aware date and time macros: `/today`, `/now`, `/datetime`, `/tomorrow`, `/yesterday`,
/// `/noon`, `/midnight`, weekday navigation (`/next-fri`, also `/next fri` and `/nextfri`), and
/// relative offsets (`/+3d`, `/-5d`, `/+2w`, `/+1mo`, `/+1y`, with spelled-out units like `/+1week`).
/// Common short forms are accepted too (`/tdy`, `/tmrw`, `/rn`). An optional format argument tunes
/// the output: `/today(iso)`, `/today(long)`, `/today(short)`, `/now(24h)`.
///
/// Pure given an injected clock so tests are deterministic. Output respects `Locale.current`; the
/// input keywords are fixed (English), like code, so they do not change per locale.
struct DateMacroEvaluator: MacroEvaluating {
    private let now: () -> Date
    private let calendar: Calendar
    private let locale: Locale

    init(now: @escaping () -> Date, calendar: Calendar = .current, locale: Locale = .current) {
        self.now = now
        var resolved = calendar
        resolved.locale = locale
        self.calendar = resolved
        self.locale = locale
    }

    func evaluate(_ query: String) -> MacroResult? {
        let lower = query.lowercased()
        let (rawBase, argument) = Self.splitArgument(lower)
        let base = Self.canonicalBase(rawBase)

        if let relative = relativeDate(base) {
            return MacroResult(formatDate(relative, style: dateStyle(for: argument)))
        }

        switch base {
        case "today", "date":
            return MacroResult(formatDate(now(), style: dateStyle(for: argument)))
        case "tomorrow":
            return offsetDays(1).map { MacroResult(formatDate($0, style: dateStyle(for: argument))) }
        case "yesterday":
            return offsetDays(-1).map { MacroResult(formatDate($0, style: dateStyle(for: argument))) }
        case "now", "time":
            return MacroResult(formatTime(now(), use24Hour: argument == "24h"))
        case "datetime":
            return MacroResult(formatDateTime(now()))
        case "noon":
            return timeOfDay(hour: 12).map { MacroResult(formatTime($0, use24Hour: argument == "24h")) }
        case "midnight":
            return timeOfDay(hour: 0).map { MacroResult(formatTime($0, use24Hour: argument == "24h")) }
        default:
            break
        }

        if let weekday = weekdayDate(base) {
            return MacroResult(formatDate(weekday, style: dateStyle(for: argument)))
        }

        return nil
    }

    // MARK: - Date computation

    private func offsetDays(_ days: Int) -> Date? {
        calendar.date(byAdding: .day, value: days, to: now())
    }

    private func timeOfDay(hour: Int) -> Date? {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now())
    }

    /// Parses relative offsets like `+3d`, `-5d`, `+2w`, `+1mo`, `+1y`.
    private func relativeDate(_ base: String) -> Date? {
        guard let sign = base.first, sign == "+" || sign == "-" else { return nil }
        let rest = base.dropFirst()
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, let magnitude = Int(digits) else { return nil }
        let unit = String(rest.dropFirst(digits.count))
        let value = (sign == "-" ? -1 : 1) * magnitude
        switch unit {
        case "d", "day", "days": return calendar.date(byAdding: .day, value: value, to: now())
        case "w", "wk", "wks", "week", "weeks": return calendar.date(byAdding: .weekOfYear, value: value, to: now())
        case "mo", "month", "months": return calendar.date(byAdding: .month, value: value, to: now())
        case "y", "yr", "yrs", "year", "years": return calendar.date(byAdding: .year, value: value, to: now())
        default: return nil
        }
    }

    /// Resolves `next-<weekday>`, `this-<weekday>`, `last-<weekday>`. `next` is the next occurrence
    /// strictly after today (a full week out if today already is that weekday); `this` includes
    /// today; `last` is the previous occurrence strictly before today.
    private func weekdayDate(_ base: String) -> Date? {
        let parts = base.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2, let target = Self.weekdays[parts[1]] else { return nil }
        let todayWeekday = calendar.component(.weekday, from: now())
        let forward = (target - todayWeekday + 7) % 7   // 0...6 days until the next target weekday
        let delta: Int
        switch parts[0] {
        case "this":
            delta = forward
        case "next":
            delta = forward == 0 ? 7 : forward
        case "last":
            delta = forward == 0 ? -7 : forward - 7
        default:
            return nil
        }
        return calendar.date(byAdding: .day, value: delta, to: now())
    }

    // MARK: - Formatting

    private enum Style {
        case iso, short, medium, long
    }

    private func dateStyle(for argument: String?) -> Style {
        switch argument {
        case "iso": return .iso
        case "long": return .long
        case "short": return .short
        default: return .medium
        }
    }

    private func formatDate(_ date: Date, style: Style) -> String {
        if style == .iso {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .none
        switch style {
        case .short: formatter.dateStyle = .short
        case .long: formatter.dateStyle = .long
        default: formatter.dateStyle = .medium
        }
        return formatter.string(from: date)
    }

    private func formatTime(_ date: Date, use24Hour: Bool) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = calendar.timeZone
        if use24Hour {
            // A fixed 24-hour format overrides the locale's 12/24-hour preference; POSIX avoids AM/PM.
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        }
        return formatter.string(from: date)
    }

    private func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Tables

    private static func splitArgument(_ string: String) -> (String, String?) {
        guard let open = string.firstIndex(of: "("), string.hasSuffix(")") else {
            return (string, nil)
        }
        let base = String(string[string.startIndex..<open])
        let argument = String(string[string.index(after: open)..<string.index(before: string.endIndex)])
        return (base, argument.isEmpty ? nil : argument)
    }

    /// Common short forms and misspellings mapped to a canonical keyword, applied before matching so
    /// `/tdy`, `/tmrw`, `/rn`, and friends resolve. Weekday navigation (`next fri`, `nextfri`) is
    /// normalized separately in `canonicalBase` because it is prefix-based rather than a fixed word.
    private static let baseAliases: [String: String] = [
        "tdy": "today", "tod": "today", "tody": "today", "2day": "today",
        "tmr": "tomorrow", "tmrw": "tomorrow", "tmw": "tomorrow", "tom": "tomorrow", "tomo": "tomorrow",
        "tomorow": "tomorrow", "2moro": "tomorrow", "2mrw": "tomorrow",
        "yest": "yesterday", "yday": "yesterday", "ystdy": "yesterday", "yesty": "yesterday", "yesterdy": "yesterday",
        "rn": "now", "rightnow": "now", "atm": "now",
        "midday": "noon", "noontime": "noon", "midnite": "midnight",
        "dt": "datetime"
    ]

    /// Normalizes a base keyword: applies `baseAliases`, then rewrites a `next`/`this`/`last` weekday
    /// prefix written with a space or no separator (`next fri`, `nextfri`) into the dash form the
    /// weekday resolver expects (`next-fri`).
    private static func canonicalBase(_ base: String) -> String {
        if let alias = baseAliases[base] {
            return alias
        }
        for prefix in ["next", "this", "last"] where base.hasPrefix(prefix) && base.count > prefix.count {
            let rest = base.dropFirst(prefix.count).drop { $0 == " " || $0 == "-" || $0 == "_" }
            if !rest.isEmpty {
                return "\(prefix)-\(rest)"
            }
        }
        return base
    }

    /// Maps weekday tokens to `Calendar` weekday indices (Sunday = 1 ... Saturday = 7).
    private static let weekdays: [String: Int] = [
        "sun": 1, "sunday": 1,
        "mon": 2, "monday": 2,
        "tue": 3, "tues": 3, "tuesday": 3,
        "wed": 4, "weds": 4, "wednesday": 4,
        "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
        "fri": 6, "friday": 6,
        "sat": 7, "saturday": 7
    ]
}
