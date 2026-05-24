import SwiftUI

/// File overview:
/// Renders the tiny always-visible menu-bar label. This view stays intentionally separate from
/// the larger menu content so the menu-bar extra can stay minimal even as the panel layout evolves.
///
/// This label lives in its own view because `MenuBarExtra` does not automatically observe
/// plain properties hanging off `AppDelegate`. By observing the models directly here,
/// SwiftUI knows when to redraw the menu bar item.
struct MenuBarStatusLabelView: View {
    @ObservedObject var suggestionCoordinator: SuggestionCoordinator

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "pawprint.fill")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 13, weight: .semibold))

            if suggestionCoordinator.totalTabAcceptedWordCount > 0 {
                Text(formattedWordCount)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
        }
    }

    private var formattedWordCount: String {
        let count = suggestionCoordinator.totalTabAcceptedWordCount
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
