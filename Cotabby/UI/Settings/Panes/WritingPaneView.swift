import SwiftUI

/// File overview:
/// "Writing" detail pane of the redesigned Settings window. Owns how the completion reads:
/// preferred length, profile (display name), preferred response languages, and the user's custom
/// style rules. Lifted from the legacy `SettingsView.writingSection` so the controls inside the
/// pane behave identically; only the wrapping form scaffold is new.
struct WritingPaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    var body: some View {
        SettingsPaneScaffold {
            Section("Writing") {
                Picker("Length", selection: selectedWordCountPresetBinding) {
                    ForEach(SuggestionWordCountPreset.allCases) { preset in
                        Text(preset.displayLabel).tag(preset)
                    }
                }
            }

            Section("Profile") {
                VStack(alignment: .leading, spacing: 24) {
                    Text("This information is passed to the AI to help personalize your completions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Name")
                            .font(.system(size: 13, weight: .medium))

                        TextField("What should Cotabby call you?", text: Binding(
                            get: { suggestionSettings.userName },
                            set: { suggestionSettings.setUserName($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }

                    LanguageTagsEditor(suggestionSettings: suggestionSettings)

                    CustomRulesEditor(suggestionSettings: suggestionSettings)
                }
                .padding(.vertical, 10)
            }
        }
    }

    private var selectedWordCountPresetBinding: Binding<SuggestionWordCountPreset> {
        Binding(
            get: { suggestionSettings.selectedWordCountPreset },
            set: { suggestionSettings.selectWordCountPreset($0) }
        )
    }
}
