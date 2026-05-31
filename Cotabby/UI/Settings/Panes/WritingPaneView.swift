import SwiftUI

/// File overview:
/// "Writing" detail pane of the redesigned Settings window. Owns how the completion reads:
/// preferred length, profile (display name), preferred response languages, and the user's custom
/// style rules.
struct WritingPaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    var body: some View {
        SettingsPaneScaffold {
            Section("Length") {
                Picker(selection: selectedWordCountPresetBinding) {
                    ForEach(SuggestionWordCountPreset.allCases) { preset in
                        Text(preset.displayLabel).tag(preset)
                    }
                } label: {
                    SettingsRowLabel(
                        title: "Length",
                        description: "How many words Cotabby aims for per suggestion. Shorter is snappier; " +
                            "longer covers more thoughts but takes longer to generate."
                    )
                }
            }

            Section("Profile") {
                VStack(alignment: .leading, spacing: 16) {
                    // The caption introduces all three personalization inputs (name, languages,
                    // rules) since each is passed to the AI, even though they live in separate cards.
                    Text("Your name, languages, and rules are passed to the AI to help personalize your completions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Name")
                            .font(.system(size: 13, weight: .medium))

                        TextField("What should Cotabby call you?", text: Binding(
                            get: { suggestionSettings.userName },
                            set: { suggestionSettings.setUserName($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.vertical, 6)
            }

            // The editors suppress their own titles here so the Section headers ("Languages"/"Rules")
            // carry the heading, matching the explicit-header pattern used across the pane.
            Section("Languages") {
                LanguageTagsEditor(suggestionSettings: suggestionSettings, showsTitleHeader: false)
                    .padding(.vertical, 6)
            }

            Section("Rules") {
                CustomRulesEditor(suggestionSettings: suggestionSettings, showsTitleHeader: false)
                    .padding(.vertical, 6)
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
