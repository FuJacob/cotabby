import SwiftUI

/// File overview:
/// "Emoji" detail pane: the inline emoji picker feature and its presentation options, split out of
/// the old General pane so the feature has a home of its own. The skin-tone and people-style options
/// only appear when the picker is enabled, so the pane stays empty-handed when the feature is off.
struct EmojiPaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    let clearEmojiHistory: () -> Void

    var body: some View {
        SettingsPaneScaffold {
            Section("Emoji Picker") {
                Toggle(isOn: emojiPickerEnabledBinding) {
                    SettingsRowLabel(
                        title: "Inline Emoji Picker",
                        description: "Type a name like :smile to search inline, then press your accept-word " +
                            "shortcut to insert the selected emoji.",
                        systemImage: "face.smiling"
                    )
                }
                .settingsItem(.emojiPicker)
            }

            if suggestionSettings.isEmojiPickerEnabled {
                Section("Suggestions") {
                    LabeledContent {
                        HStack(spacing: 8) {
                            ForEach(EmojiSkinTone.allCases, id: \.self) { tone in
                                skinToneOption(for: tone)
                            }
                        }
                    } label: {
                        SettingsRowLabel(
                            title: "Skin Tone",
                            description: "For non-default tones, suggestions show your selected tone first " +
                                "and keep the default emoji next.",
                            systemImage: "hand.raised.fingers.spread"
                        )
                    }
                    .settingsItem(.emojiSkinTone)

                    LabeledContent {
                        HStack(spacing: 8) {
                            ForEach(EmojiGender.allCases, id: \.self) { gender in
                                emojiGenderOption(for: gender)
                            }
                        }
                    } label: {
                        SettingsRowLabel(
                            title: "People Emoji Style",
                            description: "Choose person, man, or woman variants when an emoji offers them.",
                            systemImage: "person.2"
                        )
                    }
                    .settingsItem(.emojiPeopleStyle)

                    LabeledContent {
                        Button("Clear History") {
                            clearEmojiHistory()
                        }
                    } label: {
                        SettingsRowLabel(
                            title: "Emoji History",
                            description: "Forget recently and frequently used emoji so the picker ranks from scratch.",
                            systemImage: "clock.arrow.circlepath"
                        )
                    }
                    .settingsItem(.emojiHistory)
                }
            }
        }
    }

    // MARK: - Bindings

    private var emojiPickerEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isEmojiPickerEnabled },
            set: { suggestionSettings.setEmojiPickerEnabled($0) }
        )
    }

    // MARK: - Option buttons

    @ViewBuilder
    private func skinToneOption(for tone: EmojiSkinTone) -> some View {
        let isSelected = suggestionSettings.preferredEmojiSkinTone == tone

        Button {
            suggestionSettings.setPreferredEmojiSkinTone(tone)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Text(tone.sampleGlyph)
                    .font(.system(size: 19))
                    .frame(width: 34, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.primary.opacity(0.16),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                        .offset(x: 3, y: 3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("\(tone.displayName) skin tone")
        .accessibilityLabel("\(tone.displayName) skin tone")
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    @ViewBuilder
    private func emojiGenderOption(for gender: EmojiGender) -> some View {
        let isSelected = suggestionSettings.preferredEmojiGender == gender

        Button {
            suggestionSettings.setPreferredEmojiGender(gender)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Text(gender.sampleGlyph)
                    .font(.system(size: 19))
                    .frame(width: 34, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.primary.opacity(0.16),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                        .offset(x: 3, y: 3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("\(gender.displayName) variant")
        .accessibilityLabel("\(gender.displayName) variant")
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}
