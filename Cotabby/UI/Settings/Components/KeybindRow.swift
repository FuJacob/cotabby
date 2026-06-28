import SwiftUI

/// Shared row chrome for one keybinding. Owns the keycap / Change / Reset / Clear layout and the
/// `KeyRecorderView` recording state hand-off so callers stay focused on what each binding does
/// rather than how it is rendered. Extracted from `ShortcutsPaneView` so the per-app shortcuts
/// section in `AppsPaneView` can reuse the identical chrome (and so the two panes can't drift).
struct KeybindRow: View {
    let label: String
    let keyCode: CGKeyCode
    let modifiers: ShortcutModifierMask
    let defaultKeyCode: CGKeyCode
    @Binding var isRecording: Bool
    let onRecord: (CGKeyCode, ShortcutModifierMask, String) -> Void
    /// `nil` hides the Reset button — used by bindings whose only sensible "reset" is unbind, which
    /// the Clear button already covers (e.g. the opt-in global-toggle hotkey, and per-app overrides
    /// where "reset to global" is a different gesture than the recorder's factory default).
    let onReset: (() -> Void)?
    let onClear: () -> Void
    let clearHelp: String
    /// Names the action that already owns a proposed combo so the recorder can block duplicates.
    let conflictChecker: (CGKeyCode, ShortcutModifierMask) -> String?

    var body: some View {
        HStack(spacing: 8) {
            // The same physical-keycap chrome the onboarding keys step renders, so a binding looks
            // like the same object on both surfaces.
            KeycapView(label: label, fontSize: 12, minWidth: 36)

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
                .help(clearHelp)
            }
        }
    }
}
