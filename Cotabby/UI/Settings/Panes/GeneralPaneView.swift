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
                Toggle("Enable Globally", isOn: globallyEnabledBinding)

                // Fast Mode is the most user-facing performance lever, so it gets prime real
                // estate at the top. The "(no screen context)" suffix tells the user concretely
                // what gets skipped so they can decide whether they care.
                Toggle("Fast Mode (no screen context)", isOn: fastModeEnabledBinding)
            }

            Section("Behavior") {
                Toggle("Include Clipboard Context", isOn: clipboardContextEnabledBinding)

                Toggle("Allow Multi-line Suggestions", isOn: multiLineEnabledBinding)

                Toggle("Accept Punctuation With Word", isOn: autoAcceptTrailingPunctuationBinding)

                Toggle("Inline Emoji Picker", isOn: emojiPickerEnabledBinding)
                    .help(
                        "Type a colon and a name like :smile to pick an emoji inline, " +
                        "then press Tab or Return to insert it."
                    )
            }

            Section("Display") {
                Picker("Suggestion Display", selection: mirrorPreferenceBinding) {
                    ForEach(MirrorPreference.allCases) { preference in
                        Text(preference.displayLabel).tag(preference)
                    }
                }
                .pickerStyle(.menu)
                .help(
                    "Auto uses inline ghost text when the focused field exposes a reliable cursor " +
                    "position, and switches to a popup card when it doesn't (some Electron and web " +
                    "editors). Choose Inline or Popup to pin one style for every app."
                )

                Toggle("Show Indicator", isOn: showIndicatorBinding)

                Toggle("Show Word Count in Menu Bar", isOn: menuBarWordCountVisibleBinding)

                Toggle(isOn: showAcceptanceHintBinding) {
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
