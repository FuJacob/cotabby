import SwiftUI

/// File overview:
/// "General" detail pane of the redesigned Settings window. Owns the everyday on/off toggles, the
/// ghost-text appearance controls, and the onboarding re-entry. Lifted intact from the legacy
/// `SettingsView.generalSection` so behavior, bindings, and tooltip copy stay identical; only the
/// scaffolding around the form is new.
struct GeneralPaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    let onShowWelcome: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SettingsPaneScaffold {
            Section("General") {
                Toggle("Enable Globally", isOn: globallyEnabledBinding)
                    .cotabbyHelp("Master switch. Turn off to silence Cotabby in every app.")

                Toggle("Show Indicator", isOn: showIndicatorBinding)
                    .cotabbyHelp("Show a small icon next to the cursor when Cotabby is active in a field.")

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
                .cotabbyHelp("Show a small label near the ghost text reminding you which key accepts it.")

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

                Toggle("Allow Multi-line Suggestions", isOn: multiLineEnabledBinding)
                    .cotabbyHelp("Let suggestions span more than one line. Off keeps them to a single line.")

                Toggle("Accept Punctuation With Word", isOn: autoAcceptTrailingPunctuationBinding)
                    .cotabbyHelp("With this on, accepting a word also takes punctuation attached to it, like the \"?\" in \"you?\".")

                Toggle("Include Clipboard Context", isOn: clipboardContextEnabledBinding)
                    .cotabbyHelp("Include your latest clipboard contents in the prompt so completions can reference what you copied.")

                Toggle("Fast Mode", isOn: fastModeEnabledBinding)
                    .cotabbyHelp("Skip on-screen OCR context for faster, lower-overhead suggestions. Predictions still run.")

                LabeledContent("Ghost Text Color") {
                    HStack(spacing: 8) {
                        ForEach(GhostTextColorPreset.all) { preset in
                            ghostColorSwatch(for: preset)
                        }
                    }
                }
                .cotabbyHelp("Color of the ghost text shown before you accept it.")

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
                .cotabbyHelp("How visible the ghost text is. Lower values are subtler but harder to read.")

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
        .cotabbyHelp(preset.name)
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
