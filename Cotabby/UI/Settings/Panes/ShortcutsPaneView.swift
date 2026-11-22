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

                // One slot, one shortcut: either a one-press key or a double press of Accept Word.
                // The recorder takes either, so the gesture is set where users look for it.
                LabeledContent {
                    KeybindRow(
                        label: suggestionSettings.fullAcceptanceDisplayLabel,
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
                        shouldShowReset: !suggestionSettings.isFullAcceptanceShortcutDefault,
                        onClear: { suggestionSettings.clearFullAcceptanceKey() },
                        clearLabel: "Clear",
                        clearHelp: "Unbind this shortcut. No key will accept the whole suggestion at once.",
                        conflictChecker: { keyCode, modifiers in
                            suggestionSettings.conflictingShortcutName(
                                keyCode: keyCode,
                                modifiers: modifiers,
                                excluding: .acceptEntireSuggestion
                            )
                        },
                        isBound: suggestionSettings.hasFullAcceptanceShortcut,
                        doubleTapKey: acceptWordDoubleTapKey,
                        onDoubleTapRecorded: { suggestionSettings.setDoubleTapFullAcceptance() }
                    )
                } label: {
                    SettingsRowLabel(
                        title: "Accept Entire Suggestion",
                        description: fullAcceptanceDescription,
                        systemImage: "text.insert"
                    )
                }
                .settingsItem(.acceptEntireSuggestion)

                // Forms: with Accept Word on plain Tab, a visible suggestion otherwise traps Tab in
                // name, address, and search inputs. Only plain Tab is affected; other keys still accept.
                // Stays editable while a double tap accepts everything: that mode only pauses it in
                // apps that inherit the double tap, and apps with their own full-accept key still use it.
                Toggle(isOn: tabLeavesSingleLineFieldsBinding) {
                    SettingsRowLabel(
                        title: "Tab Moves to Next Field",
                        description: tabLeavesSingleLineFieldsDescription,
                        systemImage: "arrow.right.to.line.compact"
                    )
                }
                .settingsItem(.tabLeavesSingleLineFields)

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

    private var tabLeavesSingleLineFieldsDescription: String {
        let base = "In one-line fields such as form inputs, Tab moves to the next field instead of accepting. "
            + "Chat apps and editors keep accepting with Tab. "
        // The double tap only collides with this when it is a double tap of plain Tab, the one key
        // this setting hands back to the host.
        let acceptWordIsPlainTab = suggestionSettings.acceptanceKeyCode == Self.tabKeyCode
            && suggestionSettings.acceptanceKeyModifiers.isEmpty
        if suggestionSettings.isDoubleTapFullAcceptanceActive, acceptWordIsPlainTab {
            return base + "While Accept Entire Suggestion is \(suggestionSettings.fullAcceptanceDisplayLabel), "
                + "Tab keeps accepting so the double tap can complete, except in apps with their own "
                + "Accept Entire Suggestion key."
        }
        return base + "Accept Entire Suggestion keeps working on its own key. Only applies while Accept Word is Tab."
    }

    private static let tabKeyCode: CGKeyCode = 48

    private var tabLeavesSingleLineFieldsBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.tabLeavesSingleLineFields },
            set: { suggestionSettings.setTabLeavesSingleLineFields($0) }
        )
    }

    /// The Accept Word key, offered to the recorder as a double press. Nil while Accept Word is
    /// unbound, because there is then no key to press twice.
    private var acceptWordDoubleTapKey: DoubleTapRecordingKey? {
        guard suggestionSettings.acceptanceKeyCode != SuggestionSettingsModel.disabledKeyCode else {
            return nil
        }
        return DoubleTapRecordingKey(
            keyCode: suggestionSettings.acceptanceKeyCode,
            modifiers: suggestionSettings.acceptanceKeyModifiers,
            label: suggestionSettings.acceptanceKeyLabel
        )
    }

    private var fullAcceptanceDescription: String {
        let wordKey = suggestionSettings.acceptanceKeyLabel
        if suggestionSettings.isDoubleTapFullAcceptanceActive {
            // The first press of the pair follows the Mode picker above, so name what it inserts.
            let singlePress = suggestionSettings.acceptanceGranularity == .phrase ? "phrase" : "word"
            return "Press \(wordKey) twice quickly to insert the whole suggestion. "
                + "A single press still inserts the next \(singlePress)."
        }
        if acceptWordDoubleTapKey != nil {
            return "Insert the whole remaining suggestion at once. For a double tap, click Change and press \(wordKey) twice."
        }
        return "Insert the whole remaining suggestion in one keystroke."
    }
}
