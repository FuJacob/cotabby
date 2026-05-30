import SwiftUI

/// File overview:
/// "General" detail pane of the redesigned Settings window. Groups settings into four visually
/// separated `Section`s (`.formStyle(.grouped)` renders each as its own rounded card, which is
/// the macOS-native equivalent of a divider): top-level on/off toggles, behavior tuning, display
/// surface, and appearance. The `Display` picker label here matches the same name used by the
/// menu-bar quick control so users can connect the two.
struct GeneralPaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    let onShowWelcome: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SettingsPaneScaffold {
            Section("Status") {
                Toggle(isOn: globallyEnabledBinding) {
                    SettingsRowLabel(
                        title: "Enable Globally",
                        description: "Turn Cotabby off everywhere without quitting the app."
                    )
                }

                Toggle(isOn: fastModeEnabledBinding) {
                    SettingsRowLabel(
                        title: "Fast Mode",
                        description: "Skip the screenshot-based context step for faster suggestions. " +
                            "Suggestions rely only on the text you've typed."
                    )
                }
            }

            Section("Behavior") {
                Toggle(isOn: clipboardContextEnabledBinding) {
                    SettingsRowLabel(
                        title: "Include Clipboard Context",
                        description: "Let suggestions reference whatever you most recently copied."
                    )
                }

                Toggle(isOn: multiLineEnabledBinding) {
                    SettingsRowLabel(
                        title: "Allow Multi-line Suggestions",
                        description: "Allow continuations that span more than one line. Off keeps suggestions to a single line."
                    )
                }

                Toggle(isOn: autoAcceptTrailingPunctuationBinding) {
                    SettingsRowLabel(
                        title: "Accept Punctuation With Word",
                        description: "When you accept a word, also accept the punctuation that follows it " +
                            "(commas, periods) so you don't have to type it."
                    )
                }

                Toggle(isOn: emojiPickerEnabledBinding) {
                    SettingsRowLabel(
                        title: "Inline Emoji Picker",
                        description: "Type a colon and a name like :smile to pick an emoji inline, " +
                            "then press your accept-word key (Tab by default) to insert it."
                    )
                }
            }

            Section("Display") {
                // The `.help()` tooltip was promoted to inline subtext so a novice can read the
                // same guidance without knowing to hover.
                Picker(selection: mirrorPreferenceBinding) {
                    ForEach(MirrorPreference.allCases) { preference in
                        Text(preference.displayLabel).tag(preference)
                    }
                } label: {
                    SettingsRowLabel(
                        title: "Suggestion Display",
                        description: "Auto picks inline ghost text when the app's caret position is reliable, " +
                            "and a popup card when it isn't. Inline or Popup pins one style for every app."
                    )
                }
                .pickerStyle(.menu)

                Toggle(isOn: showIndicatorBinding) {
                    SettingsRowLabel(
                        title: "Show Field Indicator",
                        description: "Show a small icon at the edge of a field when Cotabby is ready to suggest."
                    )
                }

                Toggle(isOn: menuBarWordCountVisibleBinding) {
                    SettingsRowLabel(
                        title: "Show Word Count in Menu Bar",
                        description: "Show a running count of words you've accepted next to the menu bar icon."
                    )
                }

                Toggle(isOn: showAcceptanceHintBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("Show")
                            Text(suggestionSettings.acceptanceKeyLabel)
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(.quaternary)
                                )
                            Text("Key Hint")
                        }
                        Text("Show the accept-key badge next to the ghost text so you remember which key inserts it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section("Appearance") {
                LabeledContent("Ghost Text Color") {
                    HStack(spacing: 8) {
                        ForEach(GhostTextColorPreset.all) { preset in
                            ghostColorSwatch(for: preset)
                        }
                    }
                }

                LabeledContent("Ghost Text Opacity") {
                    HStack(spacing: 10) {
                        TickMarkSlider(
                            value: ghostTextOpacityBinding,
                            range: SuggestionSettingsModel.minimumGhostTextOpacity
                                ... SuggestionSettingsModel.maximumGhostTextOpacity,
                            step: SuggestionSettingsModel.ghostTextOpacityStep
                        )
                        .frame(width: 180)

                        Text(ghostTextOpacityLabel)
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }

            Section("Help") {
                LabeledContent("Onboarding") {
                    Button("Open Welcome Guide") {
                        onShowWelcome()
                    }
                }
            }
        }
    }

    // MARK: - Bindings

    private var globallyEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isGloballyEnabled },
            set: { suggestionSettings.setGloballyEnabled($0) }
        )
    }

    private var showIndicatorBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.showIndicator },
            set: { suggestionSettings.setShowIndicator($0) }
        )
    }

    private var showAcceptanceHintBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.showAcceptanceHint },
            set: { suggestionSettings.setShowAcceptanceHint($0) }
        )
    }

    private var mirrorPreferenceBinding: Binding<MirrorPreference> {
        Binding(
            get: { suggestionSettings.mirrorPreference },
            set: { suggestionSettings.setMirrorPreference($0) }
        )
    }

    private var multiLineEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isMultiLineEnabled },
            set: { suggestionSettings.setMultiLineEnabled($0) }
        )
    }

    private var emojiPickerEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isEmojiPickerEnabled },
            set: { suggestionSettings.setEmojiPickerEnabled($0) }
        )
    }

    private var autoAcceptTrailingPunctuationBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.autoAcceptTrailingPunctuation },
            set: { suggestionSettings.setAutoAcceptTrailingPunctuation($0) }
        )
    }

    private var clipboardContextEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isClipboardContextEnabled },
            set: { suggestionSettings.setClipboardContextEnabled($0) }
        )
    }

    private var fastModeEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isFastModeEnabled },
            set: { suggestionSettings.setFastModeEnabled($0) }
        )
    }

    private var menuBarWordCountVisibleBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isMenuBarWordCountVisible },
            set: { suggestionSettings.setMenuBarWordCountVisible($0) }
        )
    }

    private var ghostTextOpacityBinding: Binding<Double> {
        Binding(
            get: { suggestionSettings.ghostTextOpacity },
            set: { suggestionSettings.setGhostTextOpacity($0) }
        )
    }

    // MARK: - Ghost color swatch helpers

    /// Mirrors the overlay's automatic fallback (`GhostSuggestionView.ghostColor`) so the Automatic
    /// swatch previews the same gray the user will actually see.
    private var automaticGhostTextColor: Color {
        colorScheme == .dark
            ? Color(red: 0.65, green: 0.65, blue: 0.65)
            : Color(red: 0.45, green: 0.45, blue: 0.45)
    }

    private var ghostTextOpacityLabel: String {
        "\(Int((suggestionSettings.ghostTextOpacity * 100).rounded()))%"
    }

    @ViewBuilder
    private func ghostColorSwatch(for preset: GhostTextColorPreset) -> some View {
        let isSelected = GhostTextColorPreset.matching(
            hex: suggestionSettings.customSuggestionTextColorHex
        ) == preset

        Button {
            suggestionSettings.setCustomSuggestionTextColorHex(preset.hex)
        } label: {
            Circle()
                .fill(swatchFill(for: preset))
                .frame(width: 18, height: 18)
                .overlay(
                    Circle()
                        .strokeBorder(
                            Color.primary.opacity(isSelected ? 0.9 : 0.18),
                            lineWidth: isSelected ? 2 : 1
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func swatchFill(for preset: GhostTextColorPreset) -> Color {
        guard let hex = preset.hex,
              let color = SuggestionTextColorCodec.color(fromHex: hex)
        else {
            return automaticGhostTextColor
        }

        return color
    }
}
