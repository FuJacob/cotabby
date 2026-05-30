import SwiftUI

/// File overview:
/// Renders the tiny always-visible menu-bar label. This view stays intentionally separate from
/// the larger menu content so the menu-bar extra can stay minimal even as the panel layout evolves.
///
/// This label lives in its own view because `MenuBarExtra` does not automatically observe
/// plain properties hanging off `AppDelegate`. By observing the coordinator directly here,
/// SwiftUI knows when to redraw the menu bar item as the accepted word count changes.
struct MenuBarStatusLabelView: View {
    @ObservedObject var suggestionCoordinator: SuggestionCoordinator
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    var body: some View {
        HStack(spacing: 2) {
            Image("MenuBarCatIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 16)

            if suggestionSettings.isMenuBarWordCountVisible,
               let label = WordCountFormatter.compactLabel(
                   for: suggestionCoordinator.totalTabAcceptedWordCount
               ) {
                Text(label)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
            }
        }
    }
}
