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
                Toggle(isOn: suggestionSettings.binding(\.isEmojiPickerEnabled) { $0.setEmojiPickerEnabled($1) }) {
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

    // MARK: - Option buttons

    private func skinToneOption(for tone: EmojiSkinTone) -> some View {
        emojiOptionButton(
            glyph: tone.sampleGlyph,
            isSelected: suggestionSettings.preferredEmojiSkinTone == tone,
            help: "\(tone.displayName) skin tone"
        ) {
            suggestionSettings.setPreferredEmojiSkinTone(tone)
        }
    }

    private func emojiGenderOption(for gender: EmojiGender) -> some View {
        emojiOptionButton(
            glyph: gender.sampleGlyph,
            isSelected: suggestionSettings.preferredEmojiGender == gender,
            help: "\(gender.displayName) variant"
        ) {
            suggestionSettings.setPreferredEmojiGender(gender)
        }
    }

    /// One selectable glyph tile, shared by the skin-tone and people-style rows so both select
    /// and announce themselves the same way.
    private func emojiOptionButton(
        glyph: String,
        isSelected: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                Text(glyph)
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
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}
