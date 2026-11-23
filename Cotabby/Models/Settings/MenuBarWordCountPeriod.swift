import Foundation

/// File overview:
/// Which accepted-word total the menu-bar badge shows: every word accepted since install, or only
/// the words accepted today (reset at local midnight by `DailyWordCount`).
///
/// It is a settings value of its own, rather than a Bool such as "reset daily", because the two
/// choices are named periods a user picks between, and a named enum keeps the stored raw value
/// readable in `defaults read` and leaves room for another period without a migration.
/// `SuggestionSettingsStore` persists the raw value under a flat key, `SuggestionSettingsModel`
/// publishes it for Settings and `MenuBarStatusLabelView`, and it never enters the suggestion
/// pipeline's snapshot because it changes only what the badge draws.
nonisolated enum MenuBarWordCountPeriod: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    /// The lifetime total. The default, so the badge an existing install shows does not change.
    case allTime
    /// Words accepted since local midnight.
    case today

    var id: String { rawValue }

    /// Picker copy, kept beside the cases so Settings does not repeat the mapping.
    var displayLabel: String {
        switch self {
        case .allTime:
            return "All Time"
        case .today:
            return "Today"
        }
    }

    /// Picks the count the badge should draw. The coordinator keeps both totals current whichever
    /// period is selected, so switching periods shows the right number at once instead of
    /// starting a fresh count from the moment of the switch.
    func displayedCount(today: Int, allTime: Int) -> Int {
        switch self {
        case .allTime:
            return allTime
        case .today:
            return today
        }
    }
}
