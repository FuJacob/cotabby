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

            if suggestionSettings.isTemporarilyPaused || !suggestionSettings.isGloballyEnabled {
                Image(systemName: "pause.fill")
                    .font(.system(size: 8, weight: .bold))
                    .accessibilityLabel(inactiveAccessibilityLabel)
            }

            if suggestionSettings.isMenuBarWordCountVisible,
               let label = WordCountFormatter.compactLabel(
                   for: suggestionCoordinator.totalTabAcceptedWordCount
               ) {
                Text(label)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
            }
        }
    }

    /// VoiceOver needs the persistent global disable state distinguished from a temporary pause.
    /// Global disable takes precedence when both states are present because it remains in effect
    /// after the temporary pause is cleared.
    private var inactiveAccessibilityLabel: String {
        suggestionSettings.isGloballyEnabled ? "Cotabby paused" : "Cotabby disabled"
    }
}
