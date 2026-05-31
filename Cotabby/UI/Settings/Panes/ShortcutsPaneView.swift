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
            }

            Section("Keys") {
                LabeledContent {
                    KeybindRow(
                        label: suggestionSettings.acceptanceKeyLabel,
                        keyCode: suggestionSettings.acceptanceKeyCode,
                        modifiers: suggestionSettings.acceptanceKeyModifiers,
                        defaultKeyCode: SuggestionSettingsModel.defaultAcceptanceKeyCode,
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
                        onClear: { suggestionSettings.clearAcceptanceKey() },
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
                        description: "Insert the next word of the suggestion."
                    )
                }

                LabeledContent {
                    KeybindRow(
                        label: suggestionSettings.fullAcceptanceKeyLabel,
                        keyCode: suggestionSettings.fullAcceptanceKeyCode,
                        modifiers: suggestionSettings.fullAcceptanceKeyModifiers,
                        defaultKeyCode: SuggestionSettingsModel.defaultFullAcceptanceKeyCode,
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
                        onClear: { suggestionSettings.clearFullAcceptanceKey() },
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
                        description: "Insert the whole remaining suggestion in one keystroke."
                    )
                }

                // No factory default — the hotkey is opt-in, so the only "reset" gesture that
                // makes sense is "unbind", which the Clear button already covers. Passing
                // `onReset: nil` hides the Reset button entirely instead of making it a duplicate.
                LabeledContent {
                    KeybindRow(
                        label: suggestionSettings.globalToggleKeyLabel,
                        keyCode: suggestionSettings.globalToggleKeyCode,
                        modifiers: suggestionSettings.globalToggleKeyModifiers,
                        defaultKeyCode: SuggestionSettingsModel.disabledKeyCode,
                        isRecording: $isRecordingGlobalToggleKeybind,
                        onRecord: { keyCode, modifiers, label in
                            suggestionSettings.setGlobalToggleKey(
                                keyCode: keyCode,
                                modifiers: modifiers,
                                label: label
                            )
                        },
                        onReset: nil,
                        onClear: { suggestionSettings.clearGlobalToggleKey() },
                        clearHelp: "Unbind this shortcut. No key will toggle Tabby on or off.",
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
                        title: "Toggle Tabby",
                        description: "Turn Cotabby on or off globally without opening the menu bar."
                    )
                }
            }
        }
    }
}

/// Shared row chrome for one keybinding. Owns the badge / Change / Reset / Clear layout and the
/// `KeyRecorderView` recording state hand-off so the surrounding pane stays focused on what each
/// binding does rather than how it is rendered.
private struct KeybindRow: View {
    let label: String
    let keyCode: CGKeyCode
    let modifiers: ShortcutModifierMask
    let defaultKeyCode: CGKeyCode
    @Binding var isRecording: Bool
    let onRecord: (CGKeyCode, ShortcutModifierMask, String) -> Void
    /// `nil` hides the Reset button — used by bindings whose only sensible "reset" is unbind, which
    /// the Clear button already covers (e.g. the opt-in global-toggle hotkey).
    let onReset: (() -> Void)?
    let onClear: () -> Void
    let clearHelp: String
    /// Names the action that already owns a proposed combo so the recorder can block duplicates.
    let conflictChecker: (CGKeyCode, ShortcutModifierMask) -> String?

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                )

            if isRecording {
                KeyRecorderView(
                    onKeyRecorded: { keyCode, modifiers, label in
                        onRecord(keyCode, modifiers, label)
                        isRecording = false
                    },
                    onCancelled: { isRecording = false },
                    conflictChecker: conflictChecker
                )
            } else {
                Button("Change") {
                    isRecording = true
                }
            }

            if let onReset, keyCode != defaultKeyCode || !modifiers.isEmpty {
                Button("Reset") {
                    onReset()
                    isRecording = false
                }
            }

            if keyCode != SuggestionSettingsModel.disabledKeyCode {
                Button("Clear") {
                    onClear()
                    isRecording = false
                }
            }
        }
    }
}
