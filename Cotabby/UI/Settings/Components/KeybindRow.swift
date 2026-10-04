import SwiftUI

/// Shared keybinding controls used by global and per-app settings.
struct KeybindRow: View {
    let label: String
    let keyCode: CGKeyCode
    @Binding var isRecording: Bool
    let onRecord: (CGKeyCode, ShortcutModifierMask, String) -> Void
    /// `nil` hides Reset for bindings without a distinct reset action.
    let onReset: (() -> Void)?
    let resetLabel: String
    let shouldShowReset: Bool
    let onClear: () -> Void
    let clearLabel: String
    let clearHelp: String
    let conflictChecker: (CGKeyCode, ShortcutModifierMask) -> String?
    /// Overrides the "is anything bound" check behind Clear, for a binding that is not a single
    /// key code (a double tap). `nil` derives it from `keyCode`.
    var isBound: Bool?
    var doubleTapKey: DoubleTapRecordingKey?
    var onDoubleTapRecorded: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            KeycapView(label: label, fontSize: 12, minWidth: 36)

            if isRecording {
                KeyRecorderView(
                    onKeyRecorded: { keyCode, modifiers, label in
                        onRecord(keyCode, modifiers, label)
                        isRecording = false
                    },
                    onCancelled: { isRecording = false },
                    conflictChecker: conflictChecker,
                    doubleTapKey: doubleTapKey,
                    onDoubleTapRecorded: onDoubleTapRecorded.map { record in
                        {
                            record()
                            isRecording = false
                        }
                    }
                )
            } else {
                Button("Change") {
                    isRecording = true
                }
            }

            if let onReset, shouldShowReset {
                Button(resetLabel) {
                    onReset()
                    isRecording = false
                }
            }

            if isBound ?? (keyCode != SuggestionSettingsModel.disabledKeyCode) {
                Button(clearLabel) {
                    onClear()
                    isRecording = false
                }
                .help(clearHelp)
            }
        }
    }
}
