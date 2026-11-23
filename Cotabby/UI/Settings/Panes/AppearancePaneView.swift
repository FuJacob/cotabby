import SwiftUI

/// File overview:
/// "Appearance" detail pane: everything about how suggestions are presented. Two sections: Display
/// (where and how the suggestion shows) and Appearance (the ghost text's color, style, opacity, and
/// size). The `Suggestion Display` label matches the menu-bar quick control so users can connect
/// the two.
struct AppearancePaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SettingsPaneScaffold {
            Section("Display") {
                Picker(selection: suggestionSettings.binding(\.mirrorPreference) { $0.setMirrorPreference($1) }) {
                    ForEach(MirrorPreference.allCases) { preference in
                        Text(preference.displayLabel).tag(preference)
                    }
                } label: {
                    SettingsRowLabel(
                        title: "Suggestion Display",
                        description: "Auto picks inline ghost text when the app's caret position is reliable, " +
                            "and a popup card when it isn't. Inline or Popup pins one style for every app.",
                        systemImage: "text.cursor"
                    )
                }
                .pickerStyle(.menu)
                .settingsItem(.suggestionDisplay)

                Toggle(
                    isOn: suggestionSettings.binding(\.streamSuggestionsWhileGenerating) {
                        $0.setStreamSuggestionsWhileGenerating($1)
                    }
                ) {
                    SettingsRowLabel(
                        title: "Stream Suggestions While Generating",
                        description: "Reveal ghost text token-by-token as the model writes it, and let you accept " +
                            "early. Off shows each suggestion once it's fully written.",
                        systemImage: "text.append"
                    )
                }
                .settingsItem(.streamWhileGenerating)

                Toggle(isOn: suggestionSettings.binding(\.fadeInSuggestions) { $0.setFadeInSuggestions($1) }) {
                    SettingsRowLabel(
                        title: "Fade In Suggestions",
                        description: "Let a new suggestion fade in smoothly instead of appearing all at once. " +
                            "Follows the system Reduce Motion setting.",
                        systemImage: "sparkles"
                    )
                }
                .settingsItem(.fadeInSuggestions)

                // Revealed only while the fade is on, mirroring how the custom word-count range
                // exposes its fields under its own toggle. The slider runs Slow -> Fast; the binding
                // reflects that onto the stored duration, so dragging right shortens the ramp.
                if suggestionSettings.fadeInSuggestions {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text("Slow")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TickMarkSlider(
                                value: fadeSpeedBinding,
                                range: SuggestionSettingsStore.minimumFadeInDuration
                                    ... SuggestionSettingsStore.maximumFadeInDuration,
                                step: SuggestionSettingsStore.fadeInDurationStep
                            )
                            .frame(width: 150)
                            Text("Fast")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        SettingsRowLabel(
                            title: "Fade Speed",
                            description: "Drag toward Fast to make a new suggestion fade in more quickly.",
                            systemImage: "speedometer"
                        )
                    }
                }

                Toggle(isOn: suggestionSettings.binding(\.showIndicator) { $0.setShowIndicator($1) }) {
                    SettingsRowLabel(
                        title: "Show Field Indicator",
                        description: "Show a small icon at the edge of a field when Cotabby is ready to suggest.",
                        systemImage: "dot.viewfinder"
                    )
                }
                .settingsItem(.showFieldIndicator)

                Toggle(isOn: suggestionSettings.binding(\.isMenuBarWordCountVisible) { $0.setMenuBarWordCountVisible($1) }) {
                    SettingsRowLabel(
                        title: "Show Word Count in Menu Bar",
                        description: "Show a running count of words you've accepted next to the menu bar icon.",
                        systemImage: "number"
                    )
                }
                .disabled(!suggestionSettings.isMenuBarIconVisible)
                .settingsItem(.showWordCount)

                Toggle(isOn: suggestionSettings.binding(\.isMenuBarIconVisible) { $0.setMenuBarIconVisible($1) }) {
                    SettingsRowLabel(
                        title: "Show Cotabby in Menu Bar",
                        description: "Keep Cotabby's icon in the menu bar. If hidden, open Cotabby again to show Settings.",
                        systemImage: "menubar.rectangle"
                    )
                }
                .settingsItem(.showMenuBarIcon)

                Toggle(isOn: suggestionSettings.binding(\.showAcceptanceHint) { $0.setShowAcceptanceHint($1) }) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "keyboard")
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .center)
                            .accessibilityHidden(true)
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
                .settingsItem(.showKeyHint)
            }

            Section("Appearance") {
                GhostTextPreview(
                    ghostColor: resolvedGhostTextColor,
                    opacity: suggestionSettings.ghostTextOpacity,
                    // The overlay sets the multiplier aside while matching the host's size; so does this.
                    fontSize: GhostTextPreview.baseFontSize
                        * (suggestionSettings.matchesHostTextSize ? 1 : CGFloat(suggestionSettings.ghostTextSizeMultiplier)),
                    isBold: suggestionSettings.isGhostTextBold,
                    isItalic: suggestionSettings.isGhostTextItalic
                )

                LabeledContent {
                    HStack(spacing: 8) {
                        ForEach(GhostTextColorPreset.all) { preset in
                            ghostColorSwatch(for: preset)
                        }
                    }
                } label: {
                    SettingsRowLabel(
                        title: "Ghost Text Color",
                        description: "The color of the inline suggestion. Automatic adapts to light and dark; " +
                            "White suits dark editors.",
                        systemImage: "paintpalette"
                    )
                }
                .settingsItem(.ghostTextColor)

                LabeledContent {
                    HStack(spacing: 12) {
                        Toggle("Bold", isOn: suggestionSettings.binding(\.isGhostTextBold) { $0.setGhostTextBold($1) })
                        Toggle("Italic", isOn: suggestionSettings.binding(\.isGhostTextItalic) { $0.setGhostTextItalic($1) })
                    }
                    .toggleStyle(.checkbox)
                } label: {
                    SettingsRowLabel(
                        title: "Ghost Text Style",
                        description: "Draw suggestions bold, italic, or both. Accepted text keeps the field's own style.",
                        systemImage: "bold.italic.underline"
                    )
                }
                .settingsItem(.ghostTextStyle)

                LabeledContent {
                    valueSlider(
                        value: suggestionSettings.binding(\.ghostTextOpacity) { $0.setGhostTextOpacity($1) },
                        range: SuggestionSettingsStore.minimumGhostTextOpacity
                            ... SuggestionSettingsStore.maximumGhostTextOpacity,
                        step: SuggestionSettingsStore.ghostTextOpacityStep,
                        valueLabel: ghostTextOpacityLabel
                    )
                } label: {
                    SettingsRowLabel(
                        title: "Ghost Text Opacity",
                        description: "How faint the inline suggestion looks before you accept it.",
                        systemImage: "circle.lefthalf.filled"
                    )
                }
                .settingsItem(.ghostTextOpacity)

                Toggle(isOn: suggestionSettings.binding(\.matchesHostTextSize) { $0.setMatchesHostTextSize($1) }) {
                    SettingsRowLabel(
                        title: "Match Original Text Size",
                        description: "Draw suggestions at exactly the size of the text you are typing. " +
                            "The size settings below are set aside while this is on.",
                        systemImage: "equal.square"
                    )
                }
                .settingsItem(.matchHostTextSize)

                LabeledContent {
                    valueSlider(
                        value: suggestionSettings.binding(\.ghostTextSizeMultiplier) { $0.setGhostTextSizeMultiplier($1) },
                        range: SuggestionSettingsStore.minimumGhostTextSizeMultiplier
                            ... SuggestionSettingsStore.maximumGhostTextSizeMultiplier,
                        step: SuggestionSettingsStore.ghostTextSizeMultiplierStep,
                        valueLabel: ghostTextSizeLabel
                    )
                } label: {
                    SettingsRowLabel(
                        title: "Ghost Text Size",
                        description: "Fine-tune how large suggestions appear. Lower it if the ghost text looks too big.",
                        systemImage: "textformat.size"
                    )
                }
                .settingsItem(.ghostTextSize)
                .disabled(suggestionSettings.matchesHostTextSize)

                LabeledContent {
                    valueSlider(
                        value: suggestionSettings.binding(\.ghostFontSizeFloor) { $0.setGhostFontSizeFloor($1) },
                        range: SuggestionSettingsStore.minimumGhostFontSizeFloor
                            ... SuggestionSettingsStore.maximumGhostFontSizeFloor,
                        step: SuggestionSettingsStore.ghostFontSizeStep,
                        valueLabel: ghostFontSizeFloorLabel
                    )
                } label: {
                    SettingsRowLabel(
                        title: "Smallest Ghost Text",
                        description: "Suggestions never render below this size, even in fields that report tiny text.",
                        systemImage: "arrow.down.to.line"
                    )
                }
                .settingsItem(.ghostTextSizeFloor)
                .disabled(suggestionSettings.matchesHostTextSize)

                LabeledContent {
                    valueSlider(
                        value: suggestionSettings.binding(\.ghostFontSizeCeiling) { $0.setGhostFontSizeCeiling($1) },
                        range: SuggestionSettingsStore.minimumGhostFontSizeCeiling
                            ... SuggestionSettingsStore.maximumGhostFontSizeCeiling,
                        step: SuggestionSettingsStore.ghostFontSizeStep,
                        valueLabel: ghostFontSizeCeilingLabel
                    )
                } label: {
                    SettingsRowLabel(
                        title: "Largest Ghost Text",
                        description: "Suggestions never render above this size. Lower it if ghost text ever appears oversized.",
                        systemImage: "arrow.up.to.line"
                    )
                }
                .settingsItem(.ghostTextSizeCeiling)
                .disabled(suggestionSettings.matchesHostTextSize)
            }
        }
    }

    // MARK: - Sliders

    /// A tick-mark slider with its current value beside it. The fixed widths keep the four
    /// appearance sliders aligned in a column whatever each value's label reads.
    private func valueSlider(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueLabel: String
    ) -> some View {
        HStack(spacing: 10) {
            TickMarkSlider(value: value, range: range, step: step)
                .frame(width: 180)

            Text(valueLabel)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    // MARK: - Bindings

    /// The slider reads left-to-right as Slow -> Fast, but the stored value is a *duration*, which
    /// runs the other way (a faster fade is a shorter duration). Reflecting the duration across the
    /// midpoint of its range lets the plain `TickMarkSlider` — whose ticks and snapping assume an
    /// increasing value — present a speed axis with no custom AppKit work: the knob moves right as the
    /// duration shrinks. `FadeSpeedAxis.reflected` is an involution, so the same map serves get and set.
    private var fadeSpeedBinding: Binding<Double> {
        Binding(
            get: { FadeSpeedAxis.reflected(suggestionSettings.fadeInDurationSeconds) },
            set: { suggestionSettings.setFadeInDurationSeconds(FadeSpeedAxis.reflected($0)) }
        )
    }

    // MARK: - Ghost color swatch helpers

    /// Mirrors the overlay's automatic fallback (`OverlayController.ghostTextColor(for:)`) so the Automatic
    /// swatch previews the same gray the user will actually see.
    private var automaticGhostTextColor: Color {
        colorScheme == .dark
            ? Color(red: 0.65, green: 0.65, blue: 0.65)
            : Color(red: 0.45, green: 0.45, blue: 0.45)
    }

    /// Base color the live preview renders the ghost run in (before opacity): the user's custom pick,
    /// or the same adaptive gray the overlay falls back to, so the sample matches the real suggestion.
    private var resolvedGhostTextColor: Color {
        SuggestionTextColorCodec.color(fromHex: suggestionSettings.customSuggestionTextColorHex)
            ?? automaticGhostTextColor
    }

    private var ghostTextOpacityLabel: String {
        "\(Int((suggestionSettings.ghostTextOpacity * 100).rounded()))%"
    }

    /// Multiplier shown as a scale factor (e.g. "1.0×") rather than a percentage, so it reads as a
    /// size knob distinct from the opacity row's "%" right above it.
    private var ghostTextSizeLabel: String {
        String(format: "%.1f×", suggestionSettings.ghostTextSizeMultiplier)
    }

    /// Shown in points rather than a scale factor, because these are absolute clamps — unlike the
    /// multiplier row above, which is relative to whatever the host's caret implies.
    private var ghostFontSizeFloorLabel: String {
        "\(Int(suggestionSettings.ghostFontSizeFloor.rounded())) pt"
    }

    private var ghostFontSizeCeilingLabel: String {
        "\(Int(suggestionSettings.ghostFontSizeCeiling.rounded())) pt"
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
