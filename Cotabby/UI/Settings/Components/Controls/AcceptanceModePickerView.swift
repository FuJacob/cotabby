import SwiftUI

/// File overview:
/// Shared "Acceptance Mode" picker for the primary accept key, used by `ShortcutsPaneView`.
struct AcceptanceModePickerView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    var body: some View {
        Picker(selection: suggestionSettings.binding(\.acceptanceGranularity) { $0.setAcceptanceGranularity($1) }) {
            Text("Word").tag(AcceptanceGranularity.word)
            Text("Phrase").tag(AcceptanceGranularity.phrase)
        } label: {
            SettingsRowLabel(
                title: "Acceptance Mode",
                description: "What the Accept Word key takes per press. Word inserts one word at a time; " +
                    "Phrase inserts up to the next sentence break.",
                systemImage: "textformat.abc"
            )
        }
        .pickerStyle(.menu)
    }
}
