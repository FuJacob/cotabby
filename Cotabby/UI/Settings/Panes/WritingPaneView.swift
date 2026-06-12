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
                            "longer covers more thoughts but takes longer to generate.",
                        systemImage: "ruler"
                    )
                }
                .settingsItem(.length)

                // Min and Max are editable while Custom is active: type a value or nudge it with the
                // arrows. Both rows commit through `setCustomWordCountRange`, which clamps to
                // [minimumWord, maximumWord] and keeps Max >= Min, so neither a typed nor a stepped
                // value can leave the sensible range. Stacked as their own rows (rather than the old
                // side-by-side steppers) so each reads as one editable field. Shown only in Custom so
                // the curated picker stays the common path.
                if suggestionSettings.isUsingCustomWordCountRange {
                    LabeledContent("Minimum") {
                        wordCountField(value: customLowBinding, label: "Minimum word count")
                    }
                    LabeledContent("Maximum") {
                        wordCountField(value: customHighBinding, label: "Maximum word count")
                    }
                    Text("Token budget scales by your selected language. Multiple languages or a " +
                        "language Cotabby doesn't recognize use the English ratio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // What an accept inserts beyond the bare word. These shape the written output, so they sit
            // with Writing rather than General; the accept keys themselves live in the Shortcuts pane.
            Section("Acceptance") {
                Toggle(isOn: autoAcceptTrailingPunctuationBinding) {
                    SettingsRowLabel(
                        title: "Accept Punctuation With Word",
                        description: "When you accept a word, also accept the punctuation that follows it " +
                            "(commas, periods) so you don't have to type it.",
                        systemImage: "textformat.abc"
                    )
                }
                .settingsItem(.acceptPunctuation)

                Toggle(isOn: addSpaceAfterAcceptBinding) {
                    SettingsRowLabel(
                        title: "Add Space After Accepting",
                        description: "When accepting a suggestion finishes a word, also add a space so you can " +
                            "keep typing. Skipped when it already ends in punctuation or a space.",
                        systemImage: "space"
                    )
                }
                .settingsItem(.addSpaceAfterAccept)
            }

            // Typo handling is a dependency chain, so the UI discloses it progressively rather than
            // showing every control at once. The master gate ("Hide Suggestions on Typo") detects
            // misspellings; the correction actions only function while it is on; the dictionaries
            // only matter once an action can consume them. Revealing each level when it becomes
            // relevant — instead of dimming dependents in place — makes the hierarchy unmistakable:
            // turning the gate off removes the controls that depend on it. This is the established
            // master/dependent idiom in this app (see `EmojiPaneView`). The earlier flat layout put
            // all three toggles at the same visual level, so it was not obvious the gate governed the
            // other two.
            Section("Typos") {
                Toggle(isOn: suppressCompletionsOnTypoBinding) {
                    SettingsRowLabel(
                        title: "Hide Suggestions on Typo",
                        description: "Pauses normal completions while the current word looks misspelled. " +
                            "Turn this on to use the correction options.",
                        systemImage: "eye.slash"
                    )
                }
                .settingsItem(.hideSuggestionsOnTypo)
            }

            if suggestionSettings.suppressCompletionsOnTypo {
                Section("Corrections") {
                    Toggle(isOn: offerTypoCorrectionsBinding) {
                        SettingsRowLabel(
                            title: "Offer Corrections on Typo",
                            description: "Shows a green replacement you can apply with your accept key.",
                            systemImage: "checkmark.bubble"
                        )
                    }
                    .settingsItem(.offerTypoCorrections)

                    Toggle(isOn: automaticallyFixTyposBinding) {
                        SettingsRowLabel(
                            title: "Automatically Fix Typos",
                            description: "After you press Space, replaces a misspelled word without requiring your accept key.",
                            systemImage: "checkmark.circle"
                        )
                    }
                    .settingsItem(.automaticallyFixTypos)
                }

                // Dictionaries rank candidates for the two correction actions above, so they only
                // appear once at least one action is on. With neither active, choosing a dictionary
                // would have no observable effect.
                if suggestionSettings.offerTypoCorrections || suggestionSettings.automaticallyFixTypos {
                    Section("Spelling Dictionaries") {
                        SpellingDictionaryPicker(suggestionSettings: suggestionSettings)
                            .settingsItem(.spellingDictionaries)
                    }
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
                .settingsItem(.name)
            }

            // The editors suppress their own titles here so the Section headers ("Languages"/"Rules")
            // carry the heading, matching the explicit-header pattern used across the pane.
            Section("Languages") {
                LanguageTagsEditor(suggestionSettings: suggestionSettings, showsTitleHeader: false)
                    .padding(.vertical, 6)
                    .settingsItem(.languages)
            }

            // Hidden while custom rules are gated off (CustomRulesCatalog.isUserFacingEnabled). The
            // editor and its storage are intentionally kept so re-enabling is a one-line flip.
            if CustomRulesCatalog.isUserFacingEnabled {
                Section("Rules") {
                    CustomRulesEditor(suggestionSettings: suggestionSettings, showsTitleHeader: false)
                        .padding(.vertical, 6)
                        .settingsItem(.customRules)
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

    private var autoAcceptTrailingPunctuationBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.autoAcceptTrailingPunctuation },
            set: { suggestionSettings.setAutoAcceptTrailingPunctuation($0) }
        )
    }

    private var addSpaceAfterAcceptBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.addSpaceAfterAccept },
            set: { suggestionSettings.setAddSpaceAfterAccept($0) }
        )
    }

    private var suppressCompletionsOnTypoBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.suppressCompletionsOnTypo },
            set: { suggestionSettings.setSuppressCompletionsOnTypo($0) }
        )
    }

    private var offerTypoCorrectionsBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.offerTypoCorrections },
            set: { suggestionSettings.setOfferTypoCorrections($0) }
        )
    }

    private var automaticallyFixTyposBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.automaticallyFixTypos },
            set: { suggestionSettings.setAutomaticallyFixTypos($0) }
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

    /// A compact "type or step" control: a right-aligned numeric field paired with up/down arrows,
    /// both bound to the same clamping binding so a typed value and a stepped value land on the same
    /// sensible range. Factored out so the Min and Max rows stay identical. The field uses the
    /// `.number` format so it only commits a parsed integer on Return / focus loss, where the binding
    /// clamps it — intermediate keystrokes never fight the clamp. `label` is the spoken VoiceOver
    /// name: `LabeledContent`'s visible title is not applied to the controls themselves, so the field
    /// and stepper carry it explicitly (otherwise VoiceOver announces them unnamed).
    @ViewBuilder
    private func wordCountField(value: Binding<Int>, label: String) -> some View {
        HStack(spacing: 8) {
            TextField("", value: value, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
            Stepper(
                "",
                value: value,
                in: SuggestionWordRange.minimumWord...SuggestionWordRange.maximumWord
            )
            .labelsHidden()
            .accessibilityLabel(label)
        }
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
