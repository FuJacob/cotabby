import SwiftUI

/// File overview:
/// "Shortcuts" detail pane of the redesigned Settings window. Surfaces the two keybindings that
/// drive suggestion acceptance: word-by-word and full-suggestion. Lifted from the legacy
/// `SettingsView.shortcutsSection` so binding capture, conflict resolution, and reset / clear
/// semantics are preserved exactly.
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
                LabeledContent("Accept Word") {
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
                        clearHelp: "Unbind this shortcut. No key will accept word-by-word."
                    )
                }

                LabeledContent("Accept Entire Suggestion") {
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
                        clearHelp: "Unbind this shortcut. No key will accept the whole suggestion at once."
                    )
                }

                // No factory default — the hotkey is opt-in, so the only "reset" gesture that
                // makes sense is "unbind", which the Clear button already covers. Passing
                // `onReset: nil` hides the Reset button entirely instead of making it a duplicate.
                LabeledContent("Toggle Tabby") {
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
                        clearHelp: "Unbind this shortcut. No key will toggle Tabby on or off."
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
                    onCancelled: { isRecording = false }
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
