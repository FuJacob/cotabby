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
                } label: {
                    SettingsRowLabel(
                        title: "Accept Entire Suggestion",
                        description: "Insert the whole remaining suggestion in one keystroke.",
                        systemImage: "text.insert"
                    )
                }
                .settingsItem(.acceptEntireSuggestion)

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
                        clearHelp: "Unbind this shortcut. No key will toggle CoHamster on or off.",
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
                        title: "Toggle CoHamster",
                        description: "Turn CoHamster on or off globally without opening the menu bar.",
                        systemImage: "power.circle"
                    )
                }
                .settingsItem(.toggleTabby)
            }
        }
    }
}
