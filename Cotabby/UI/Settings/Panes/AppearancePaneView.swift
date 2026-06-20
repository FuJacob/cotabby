import SwiftUI

/// File overview:
/// "Appearance" detail pane: everything about how suggestions are presented, split out of the old
/// General pane so each surface has one focus. Two sections: Display (where and how the suggestion
/// shows) and Appearance (the ghost text's color and opacity). The `Suggestion Display` label
/// matches the menu-bar quick control so users can connect the two.
struct AppearancePaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SettingsPaneScaffold {
            Section("Display") {
                Picker(selection: mirrorPreferenceBinding) {
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

                Toggle(isOn: streamWhileGeneratingBinding) {
                    SettingsRowLabel(
                        title: "Stream Suggestions While Generating",
                        description: "Reveal ghost text token-by-token as the model writes it, and let you accept " +
                            "early. Off shows each suggestion once it's fully written.",
                        systemImage: "text.append"
                    )
                }
                .settingsItem(.streamWhileGenerating)

                Toggle(isOn: fadeInSuggestionsBinding) {
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
                                range: SuggestionSettingsModel.minimumFadeInDuration
                                    ... SuggestionSettingsModel.maximumFadeInDuration,
                                step: SuggestionSettingsModel.fadeInDurationStep
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

                Toggle(isOn: showIndicatorBinding) {
                    SettingsRowLabel(
                        title: "Show Field Indicator",
                        description: "Show a small icon at the edge of a field when Cotabby is ready to suggest.",
                        systemImage: "dot.viewfinder"
                    )
                }
                .settingsItem(.showFieldIndicator)

                Toggle(isOn: menuBarWordCountVisibleBinding) {
                    SettingsRowLabel(
                        title: "Show Word Count in Menu Bar",
                        description: "Show a running count of words you've accepted next to the menu bar icon.",
                        systemImage: "number"
                    )
                }
                .settingsItem(.showWordCount)

                Toggle(isOn: showAcceptanceHintBinding) {
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
                    fontSize: GhostTextPreview.baseFontSize * CGFloat(suggestionSettings.ghostTextSizeMultiplier)
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
                        description: "The color of the inline suggestion. Automatic adapts to light and dark.",
                        systemImage: "paintpalette"
                    )
                }
                .settingsItem(.ghostTextColor)

                LabeledContent {
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
                } label: {
                    SettingsRowLabel(
                        title: "Ghost Text Opacity",
                        description: "How faint the inline suggestion looks before you accept it.",
                        systemImage: "circle.lefthalf.filled"
                    )
                }
                .settingsItem(.ghostTextOpacity)

                LabeledContent {
                    HStack(spacing: 10) {
                        TickMarkSlider(
                            value: ghostTextSizeBinding,
                            range: SuggestionSettingsModel.minimumGhostTextSizeMultiplier
                                ... SuggestionSettingsModel.maximumGhostTextSizeMultiplier,
                            step: SuggestionSettingsModel.ghostTextSizeMultiplierStep
                        )
                        .frame(width: 180)

                        Text(ghostTextSizeLabel)
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                } label: {
                    SettingsRowLabel(
                        title: "Ghost Text Size",
                        description: "Fine-tune how large suggestions appear. Lower it if the ghost text looks too big.",
                        systemImage: "textformat.size"
                    )
                }
                .settingsItem(.ghostTextSize)
            }
        }
    }

    // MARK: - Bindings

    private var streamWhileGeneratingBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.streamSuggestionsWhileGenerating },
            set: { suggestionSettings.setStreamSuggestionsWhileGenerating($0) }
        )
    }

    private var fadeInSuggestionsBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.fadeInSuggestions },
            set: { suggestionSettings.setFadeInSuggestions($0) }
        )
    }

    /// The slider reads left-to-right as Slow -> Fast, but the stored value is a *duration*, which
    /// runs the other way (a faster fade is a shorter duration). Reflecting the duration across the
    /// midpoint of its range lets the plain `TickMarkSlider` — whose ticks and snapping assume an
    /// increasing value — present a speed axis with no custom AppKit work: the knob moves right as the
    /// duration shrinks. `fadeSpeedAxis` is an involution, so the same map serves get and set.
    private var fadeSpeedBinding: Binding<Double> {
        Binding(
            get: { Self.fadeSpeedAxis(suggestionSettings.fadeInDurationSeconds) },
            set: { suggestionSettings.setFadeInDurationSeconds(Self.fadeSpeedAxis($0)) }
        )
    }

    /// Reflects a value across the midpoint of the fade-duration band, mapping a stored duration to
    /// its slider position and back. Applying it twice is the identity, so get and set stay in sync.
    private static func fadeSpeedAxis(_ value: Double) -> Double {
        (SuggestionSettingsModel.minimumFadeInDuration + SuggestionSettingsModel.maximumFadeInDuration) - value
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

    private var ghostTextSizeBinding: Binding<Double> {
        Binding(
            get: { suggestionSettings.ghostTextSizeMultiplier },
            set: { suggestionSettings.setGhostTextSizeMultiplier($0) }
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
