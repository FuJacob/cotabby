import Foundation

/// A menu-bar pause choice. Calendar math lives here so the UI only expresses intent and never has
/// to decide what "tomorrow" means. Calendar-based midnight also stays correct across DST changes.
nonisolated enum SuggestionPauseDuration: CaseIterable, Identifiable {
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case untilTomorrow
    case indefinitely

    var id: Self { self }

    var menuLabel: String {
        switch self {
        case .fifteenMinutes: return "Pause for 15 Minutes"
        case .thirtyMinutes: return "Pause for 30 Minutes"
        case .oneHour: return "Pause for 1 Hour"
        case .untilTomorrow: return "Pause Until Tomorrow"
        case .indefinitely: return "Pause Until I Turn It Back On"
        }
    }

    func pauseState(
        from now: Date = Date(),
        calendar: Calendar = .current
    ) -> SuggestionPauseState {
        switch self {
        case .fifteenMinutes:
            return .until(now.addingTimeInterval(15 * 60))
        case .thirtyMinutes:
            return .until(now.addingTimeInterval(30 * 60))
        case .oneHour:
            return .until(now.addingTimeInterval(60 * 60))
        case .untilTomorrow:
            let today = calendar.startOfDay(for: now)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)
                ?? now.addingTimeInterval(24 * 60 * 60)
            return .until(tomorrow)
        case .indefinitely:
            return .indefinitely
        }
    }
}

/// Durable temporary-disable state shared by persistence, the suggestion pipeline, and menu UI.
///
/// This remains separate from `isGloballyEnabled`: a pause is session intent with an optional end,
/// while the global preference remains the user's normal operating configuration. The settings
/// model owns this value for the app lifetime and clears timed values when they expire.
nonisolated enum SuggestionPauseState: Codable, Equatable, Sendable {
    case until(Date)
    case indefinitely

    var expirationDate: Date? {
        guard case let .until(date) = self else { return nil }
        return date
    }

    func isActive(at date: Date = Date()) -> Bool {
        switch self {
        case let .until(expiration):
            return expiration > date
        case .indefinitely:
            return true
        }
    }

    func activeState(at date: Date = Date()) -> SuggestionPauseState? {
        isActive(at: date) ? self : nil
    }

    func statusText(
        at now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        guard isActive(at: now) else { return nil }

        switch self {
        case .indefinitely:
            return "Paused until enabled"
        case let .until(expiration):
            let tomorrow = calendar.date(
                byAdding: .day,
                value: 1,
                to: calendar.startOfDay(for: now)
            )
            if let tomorrow, expiration == tomorrow {
                return "Paused until tomorrow"
            }
            if calendar.isDate(expiration, inSameDayAs: now) {
                return "Paused until \(expiration.formatted(date: .omitted, time: .shortened))"
            }
            return "Paused until \(expiration.formatted(date: .abbreviated, time: .shortened))"
        }
    }
}
