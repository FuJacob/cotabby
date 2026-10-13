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
                        resetLabel: String(localized: "Reset"),
                        shouldShowReset: suggestionSettings.acceptanceKeyCode
                            != SuggestionSettingsModel.defaultAcceptanceKeyCode
                            || !suggestionSettings.acceptanceKeyModifiers.isEmpty,
                        onClear: { suggestionSettings.clearAcceptanceKey() },
                        clearLabel: String(localized: "Clear"),
                        clearHelp: String(localized: "Unbind this shortcut. No key will accept word-by-word."),
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
                        title: String(localized: "Accept Word"),
                        description: String(localized: "Insert the next word of the suggestion."),
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
                        resetLabel: String(localized: "Reset"),
                        shouldShowReset: !suggestionSettings.isFullAcceptanceShortcutDefault,
                        onClear: { suggestionSettings.clearFullAcceptanceKey() },
                        clearLabel: String(localized: "Clear"),
                        clearHelp: String(localized: "Unbind this shortcut. No key will accept the whole suggestion at once."),
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
                        title: String(localized: "Accept Entire Suggestion"),
                        description: fullAcceptanceDescription,
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
                        resetLabel: String(localized: "Reset"),
                        shouldShowReset: false,
                        onClear: { suggestionSettings.clearGlobalToggleKey() },
                        clearLabel: String(localized: "Clear"),
                        clearHelp: String(localized: "Unbind this shortcut. No key will toggle Cotabby on or off."),
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
                        title: String(localized: "Toggle Cotabby"),
                        description: String(localized: "Turn Cotabby on or off globally without opening the menu bar."),
                        systemImage: "power.circle"
                    )
                }
                .settingsItem(.toggleTabby)
            }
        }
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
            let singlePress = suggestionSettings.acceptanceGranularity == .phrase
                ? String(localized: "phrase")
                : String(localized: "word")
            return String(localized: """
            Press \(wordKey) twice quickly to insert the whole suggestion. A single press still inserts the next \
            \(singlePress).
            """)
        }
        if acceptWordDoubleTapKey != nil {
            return String(localized: """
            Insert the whole remaining suggestion at once. For a double tap, click Change and press \(wordKey) twice.
            """)
        }
        return String(localized: "Insert the whole remaining suggestion in one keystroke.")
    }
}
