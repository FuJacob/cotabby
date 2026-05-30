import SwiftUI

/// File overview:
/// Shared "Acceptance Mode" picker for the primary accept key. Used by both the legacy
/// `SettingsView.shortcutsSection` and the redesigned `ShortcutsPaneView`, so the granularity
/// labels and cases live in one place — adding or renaming a mode can't drift between the two
/// settings shells.
struct AcceptanceModePickerView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    private var acceptanceGranularityBinding: Binding<AcceptanceGranularity> {
        Binding(
            get: { suggestionSettings.acceptanceGranularity },
            set: { suggestionSettings.setAcceptanceGranularity($0) }
        )
    }

    var body: some View {
        Picker(selection: acceptanceGranularityBinding) {
            Text("Word").tag(AcceptanceGranularity.word)
            Text("Phrase").tag(AcceptanceGranularity.phrase)
        } label: {
            SettingsRowLabel(
                title: "Acceptance Mode",
                description: "What the Accept Word key takes per press. Word inserts one word at a time; " +
                    "Phrase inserts up to the next sentence break."
            )
        }
        .pickerStyle(.menu)
    }
}
