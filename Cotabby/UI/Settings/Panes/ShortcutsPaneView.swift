import SwiftUI

/// File overview:
/// "Shortcuts" detail pane of the redesigned Settings window. Surfaces the two keybindings that
/// drive suggestion acceptance: word-by-word and full-suggestion.
struct ShortcutsPaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    @State private var isRecordingKeybind = false
    @State private var isRecordingFullAcceptKeybind = false
    @State private var isRecordingGlobalToggleKeybind = false

    var body: some View {
        SettingsPaneScaffold {
            Section("Mode") {
                AcceptanceModePickerView(suggestionSettings: suggestionSettings)
                    .settingsItem(.acceptanceMode)
            }

            Section("Keys") {
                LabeledContent {
                    KeybindRow(
                        label: suggestionSettings.acceptanceKeyLabel,
                        keyCode: suggestionSettings.acceptanceKeyCode,
                        isRecording: $isRecordingKeybind,
                        onRecord: { keyCode, modifiers, label in
                            suggestionSettings.setAcceptanceKey(
                                keyCode: keyCode,
                                modifiers: modifiers,
                                label: label
                            )
                        },
                        onReset: {
                            suggestionSettings.setAcceptanceKey(
                                keyCode: SuggestionSettingsModel.defaultAcceptanceKeyCode,
                                modifiers: [],
                                label: SuggestionSettingsModel.defaultAcceptanceKeyLabel
                            )
                        },
                        resetLabel: "Reset",
                        shouldShowReset: suggestionSettings.acceptanceKeyCode
                            != SuggestionSettingsModel.defaultAcceptanceKeyCode
                            || !suggestionSettings.acceptanceKeyModifiers.isEmpty,
                        onClear: { suggestionSettings.clearAcceptanceKey() },
                        clearLabel: "Clear",
                        clearHelp: "Unbind this shortcut. No key will accept word-by-word.",
                        conflictChecker: { keyCode, modifiers in
                            suggestionSettings.conflictingShortcutName(
                                keyCode: keyCode,
                                modifiers: modifiers,
                                excluding: .acceptWord
                            )
                        }
                    )
                } label: {
                    SettingsRowLabel(
                        title: "Accept Word",
                        description: "Insert the next word of the suggestion.",
                        systemImage: "arrow.right.to.line"
                    )
                }
                .settingsItem(.acceptWord)

                LabeledContent {
                    HStack(spacing: 8) {
                        // Double-tap is a second way to fire this action, so its keys sit in this
                        // row next to the one-press binding instead of only behind the toggle below.
                        if isDoubleTapAcceptActive {
                            DoubleTapKeycaps(label: suggestionSettings.acceptanceKeyLabel)
                            if suggestionSettings.fullAcceptanceKeyCode != SuggestionSettingsModel.disabledKeyCode {
                                Text("or")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        KeybindRow(
                            label: suggestionSettings.fullAcceptanceKeyLabel,
                            keyCode: suggestionSettings.fullAcceptanceKeyCode,
                            isRecording: $isRecordingFullAcceptKeybind,
                            onRecord: { keyCode, modifiers, label in
                                suggestionSettings.setFullAcceptanceKey(
                                    keyCode: keyCode,
                                    modifiers: modifiers,
                                    label: label
                                )
                            },
                            onReset: {
                                suggestionSettings.setFullAcceptanceKey(
                                    keyCode: SuggestionSettingsModel.defaultFullAcceptanceKeyCode,
                                    modifiers: [],
                                    label: SuggestionSettingsModel.defaultFullAcceptanceKeyLabel
                                )
                            },
                            resetLabel: "Reset",
                            shouldShowReset: suggestionSettings.fullAcceptanceKeyCode
                                != SuggestionSettingsModel.defaultFullAcceptanceKeyCode
                                || !suggestionSettings.fullAcceptanceKeyModifiers.isEmpty,
                            onClear: { suggestionSettings.clearFullAcceptanceKey() },
                            clearLabel: "Clear",
                            clearHelp: "Unbind this shortcut. No key will accept the whole suggestion at once.",
                            conflictChecker: { keyCode, modifiers in
                                suggestionSettings.conflictingShortcutName(
                                    keyCode: keyCode,
                                    modifiers: modifiers,
                                    excluding: .acceptEntireSuggestion
                                )
                            }
                        )
                    }
                } label: {
                    SettingsRowLabel(
                        title: "Accept Entire Suggestion",
                        description: isDoubleTapAcceptActive
                            ? "Insert the whole remaining suggestion in one keystroke, or by pressing " +
                                "\(suggestionSettings.acceptanceKeyLabel) twice quickly."
                            : "Insert the whole remaining suggestion in one keystroke.",
                        systemImage: "text.insert"
                    )
                }
                .settingsItem(.acceptEntireSuggestion)

                // A modifier on the Accept Word key rather than its own binding: the first press still
                // takes a word immediately, and a quick second press takes the rest.
                Toggle(isOn: doubleTapAcceptsEntireSuggestionBinding) {
                    SettingsRowLabel(
                        title: "Double-Tap to Accept All",
                        description: "Press \(suggestionSettings.acceptanceKeyLabel) twice quickly to insert the " +
                            "whole suggestion. A single press still inserts one word.",
                        systemImage: "hand.tap"
                    )
                }
                .settingsItem(.doubleTapAcceptEntire)

                // The opt-in toggle has no factory binding; Clear is its only reset action.
                LabeledContent {
                    KeybindRow(
                        label: suggestionSettings.globalToggleKeyLabel,
                        keyCode: suggestionSettings.globalToggleKeyCode,
                        isRecording: $isRecordingGlobalToggleKeybind,
                        onRecord: { keyCode, modifiers, label in
                            suggestionSettings.setGlobalToggleKey(
                                keyCode: keyCode,
                                modifiers: modifiers,
                                label: label
                            )
                        },
                        onReset: nil,
                        resetLabel: "Reset",
                        shouldShowReset: false,
                        onClear: { suggestionSettings.clearGlobalToggleKey() },
                        clearLabel: "Clear",
                        clearHelp: "Unbind this shortcut. No key will toggle Cotabby on or off.",
                        conflictChecker: { keyCode, modifiers in
                            suggestionSettings.conflictingShortcutName(
                                keyCode: keyCode,
                                modifiers: modifiers,
                                excluding: .toggleTabby
                            )
                        }
                    )
                } label: {
                    SettingsRowLabel(
                        title: "Toggle Cotabby",
                        description: "Turn Cotabby on or off globally without opening the menu bar.",
                        systemImage: "power.circle"
                    )
                }
                .settingsItem(.toggleTabby)
            }
        }
    }

    /// Double-tap rides on the Accept Word key, so it can only fire while that key is bound.
    private var isDoubleTapAcceptActive: Bool {
        suggestionSettings.doubleTapAcceptsEntireSuggestion
            && suggestionSettings.acceptanceKeyCode != SuggestionSettingsModel.disabledKeyCode
    }

    private var doubleTapAcceptsEntireSuggestionBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.doubleTapAcceptsEntireSuggestion },
            set: { suggestionSettings.setDoubleTapAcceptsEntireSuggestion($0) }
        )
    }
}

/// The Accept Word key drawn twice, the way the double-tap gesture is pressed. Uses the same
/// keycap chrome and size as `KeybindRow` so it reads as part of the row's key area.
private struct DoubleTapKeycaps: View {
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            KeycapView(label: label, fontSize: 12, minWidth: 36)
            KeycapView(label: label, fontSize: 12, minWidth: 36)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) twice")
    }
}
