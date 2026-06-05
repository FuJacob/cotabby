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
                Picker(selection: lengthChoiceBinding) {
                    ForEach(SuggestionWordCountPreset.allCases) { preset in
                        Text(preset.displayLabel).tag(LengthChoice.preset(preset))
                    }
                    Text("Custom range…").tag(LengthChoice.custom)
                } label: {
                    SettingsRowLabel(
                        title: "Length",
                        description: "How many words Cotabby aims for per suggestion. Shorter is snappier; " +
                            "longer covers more thoughts but takes longer to generate."
                    )
                }

                // Two steppers appear only while Custom is active so the curated picker stays the
                // common path. `customRangeChanged` re-routes through `setCustomWordCountRange` so
                // the values are clamped and high stays >= low even if the user spams Down on high.
                if suggestionSettings.isUsingCustomWordCountRange {
                    HStack(spacing: 16) {
                        Stepper(
                            value: customLowBinding,
                            in: SuggestionWordRange.minimumWord...SuggestionWordRange.maximumWord
                        ) {
                            Text("Min: \(suggestionSettings.customWordCountLowWords)")
                        }
                        Stepper(
                            value: customHighBinding,
                            in: SuggestionWordRange.minimumWord...SuggestionWordRange.maximumWord
                        ) {
                            Text("Max: \(suggestionSettings.customWordCountHighWords)")
                        }
                    }
                    Text("Token budget scales by your selected language. Multiple languages or a " +
                        "language Cotabby doesn't recognize use the English ratio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Profile") {
                VStack(alignment: .leading, spacing: 16) {
                    // Introduces the personalization inputs passed to the AI. The custom-rules input
                    // is gated (CustomRulesCatalog.isUserFacingEnabled), so this copy and the Rules
                    // section below are dropped together while the feature is hidden.
                    Text(CustomRulesCatalog.isUserFacingEnabled
                        ? "Your name, languages, and rules are passed to the AI to help personalize your completions."
                        : "Your name and languages are passed to the AI to help personalize your completions.")
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

            // Hidden while custom rules are gated off (CustomRulesCatalog.isUserFacingEnabled). The
            // editor and its storage are intentionally kept so re-enabling is a one-line flip.
            if CustomRulesCatalog.isUserFacingEnabled {
                Section("Rules") {
                    CustomRulesEditor(suggestionSettings: suggestionSettings, showsTitleHeader: false)
                        .padding(.vertical, 6)
                }
            }
        }
    }

    private var selectedWordCountPresetBinding: Binding<SuggestionWordCountPreset> {
        Binding(
            get: { suggestionSettings.selectedWordCountPreset },
            set: { suggestionSettings.selectWordCountPreset($0) }
        )
    }

    private enum LengthChoice: Hashable {
        case preset(SuggestionWordCountPreset)
        case custom
    }

    private var lengthChoiceBinding: Binding<LengthChoice> {
        Binding(
            get: {
                suggestionSettings.isUsingCustomWordCountRange
                    ? .custom
                    : .preset(suggestionSettings.selectedWordCountPreset)
            },
            set: { choice in
                switch choice {
                case let .preset(preset):
                    suggestionSettings.setUsingCustomWordCountRange(false)
                    suggestionSettings.selectWordCountPreset(preset)
                case .custom:
                    suggestionSettings.setUsingCustomWordCountRange(true)
                }
            }
        )
    }

    private var customLowBinding: Binding<Int> {
        Binding(
            get: { suggestionSettings.customWordCountLowWords },
            set: { newLow in
                suggestionSettings.setCustomWordCountRange(
                    low: newLow,
                    high: suggestionSettings.customWordCountHighWords
                )
            }
        )
    }

    private var customHighBinding: Binding<Int> {
        Binding(
            get: { suggestionSettings.customWordCountHighWords },
            set: { newHigh in
                suggestionSettings.setCustomWordCountRange(
                    low: suggestionSettings.customWordCountLowWords,
                    high: newHigh
                )
            }
        )
    }
}
