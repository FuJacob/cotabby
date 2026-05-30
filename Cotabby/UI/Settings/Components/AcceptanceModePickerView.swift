import SwiftUI

/// File overview:
/// Shared "Acceptance Mode" picker for the primary accept key, used by `ShortcutsPaneView`.
struct AcceptanceModePickerView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    private var acceptanceGranularityBinding: Binding<AcceptanceGranularity> {
        Binding(
            get: { suggestionSettings.acceptanceGranularity },
            set: { suggestionSettings.setAcceptanceGranularity($0) }
        )
    }

    var body: some View {
        Picker("Acceptance Mode", selection: acceptanceGranularityBinding) {
            Text("Accept Word").tag(AcceptanceGranularity.word)
            Text("Phrase").tag(AcceptanceGranularity.phrase)
        }
        .pickerStyle(.menu)
    }
}
