import SwiftUI

/// File overview:
/// The onboarding "learn your keys" step: a hero keycap that demonstrates the accept gesture, plus
/// one row per rebindable shortcut (accept word, accept entire suggestion, toggle Cotabby). Rows
/// reuse the real `KeyRecorderView` and write through `SuggestionSettingsModel`, so a binding
/// recorded here is exactly the one Settings shows later.
///
/// Only one row can record at a time (`recordingAction` is a single optional rather than per-row
/// flags), which prevents two recorders from competing for the same keystroke.
struct WelcomeKeybindStepView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    @State private var recordingAction: ShortcutAction?

    var body: some View {
        VStack(spacing: 24) {
            OnboardingKeycapHero(label: suggestionSettings.acceptanceKeyLabel)
                .onboardingReveal(0)

            VStack(spacing: 8) {
                Text("Learn your keys")
                    .font(.system(size: 26, weight: .bold, design: .rounded))

                Text("Accept suggestions without leaving the keyboard.\nYou can change these anytime in Settings.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .onboardingReveal(1)

            VStack(spacing: 10) {
                keybindRow(
                    title: "Accept word",
                    keyLabel: suggestionSettings.acceptanceKeyLabel,
                    action: .acceptWord,
                    onKeyRecorded: { keyCode, modifiers, label in
                        suggestionSettings.setAcceptanceKey(
                            keyCode: keyCode,
                            modifiers: modifiers,
                            label: label
                        )
                    },
                    onReset: (
                        suggestionSettings.acceptanceKeyCode != SuggestionSettingsModel.defaultAcceptanceKeyCode
                            || !suggestionSettings.acceptanceKeyModifiers.isEmpty
                    ) ? {
                        suggestionSettings.setAcceptanceKey(
                            keyCode: SuggestionSettingsModel.defaultAcceptanceKeyCode,
                            modifiers: [],
                            label: SuggestionSettingsModel.defaultAcceptanceKeyLabel
                        )
                    } : nil,
                    onClear: suggestionSettings.acceptanceKeyCode != SuggestionSettingsModel.disabledKeyCode
                        ? { suggestionSettings.clearAcceptanceKey() } : nil
                )
                .onboardingReveal(2)

                keybindRow(
                    title: "Accept entire suggestion",
                    keyLabel: suggestionSettings.fullAcceptanceKeyLabel,
                    action: .acceptEntireSuggestion,
                    onKeyRecorded: { keyCode, modifiers, label in
                        suggestionSettings.setFullAcceptanceKey(
                            keyCode: keyCode,
                            modifiers: modifiers,
                            label: label
                        )
                    },
                    onReset: (
                        suggestionSettings.fullAcceptanceKeyCode != SuggestionSettingsModel.defaultFullAcceptanceKeyCode
                            || !suggestionSettings.fullAcceptanceKeyModifiers.isEmpty
                    ) ? {
                        suggestionSettings.setFullAcceptanceKey(
                            keyCode: SuggestionSettingsModel.defaultFullAcceptanceKeyCode,
                            modifiers: [],
                            label: SuggestionSettingsModel.defaultFullAcceptanceKeyLabel
                        )
                    } : nil,
                    onClear: suggestionSettings.fullAcceptanceKeyCode != SuggestionSettingsModel.disabledKeyCode
                        ? { suggestionSettings.clearFullAcceptanceKey() } : nil
                )
                .onboardingReveal(3)

                // No `onReset` here: the toggle hotkey is opt-in and has no factory default, so the
                // only meaningful "reset" is unbind, which the Clear button already covers.
                keybindRow(
                    title: "Toggle Cotabby",
                    keyLabel: suggestionSettings.globalToggleKeyLabel,
                    action: .toggleTabby,
                    onKeyRecorded: { keyCode, modifiers, label in
                        suggestionSettings.setGlobalToggleKey(
                            keyCode: keyCode,
                            modifiers: modifiers,
                            label: label
                        )
                    },
                    onReset: nil,
                    onClear: suggestionSettings.globalToggleKeyCode != SuggestionSettingsModel.disabledKeyCode
                        ? { suggestionSettings.clearGlobalToggleKey() } : nil
                )
                .onboardingReveal(4)
            }
            .frame(maxWidth: 480)
        }
    }

    @ViewBuilder
    private func keybindRow(
        title: String,
        keyLabel: String,
        action: ShortcutAction,
        onKeyRecorded: @escaping (CGKeyCode, ShortcutModifierMask, String) -> Void,
        onReset: (() -> Void)? = nil,
        onClear: (() -> Void)? = nil
    ) -> some View {
        let isRecording = recordingAction == action
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)

            KeycapView(label: keyLabel)

            if isRecording {
                KeyRecorderView(
                    onKeyRecorded: { keyCode, modifiers, label in
                        onKeyRecorded(keyCode, modifiers, label)
                        recordingAction = nil
                    },
                    onCancelled: {
                        recordingAction = nil
                    },
                    conflictChecker: { keyCode, modifiers in
                        suggestionSettings.conflictingShortcutName(
                            keyCode: keyCode,
                            modifiers: modifiers,
                            excluding: action
                        )
                    }
                )
            } else {
                Button("Change") {
                    recordingAction = action
                }
                .controlSize(.small)
            }

            if let onReset {
                Button("Reset") {
                    onReset()
                    recordingAction = nil
                }
                .controlSize(.small)
            }

            // Mirror the Settings "Shortcuts" pane, which offers Clear here too: unbinding a
            // shortcut mid-setup shouldn't force the user to finish onboarding and then dig through
            // Settings to undo it. Call sites pass nil while the key is already unbound, so the
            // button only appears when there is a binding to clear.
            if let onClear {
                Button("Clear") {
                    onClear()
                    recordingAction = nil
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .onboardingCard(cornerRadius: 12)
    }
}

// MARK: - Keycap hero

/// The step's hero: the user's current accept key as a large keycap that presses itself every few
/// seconds. The press is a two-frame dip (translate down, ledge shadow collapses) driven by a
/// `.task` loop; Reduce Motion holds the key at rest.
private struct OnboardingKeycapHero: View {
    let label: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false

    var body: some View {
        KeycapView(label: label, fontSize: 17, minWidth: 84)
            .scaleEffect(pressed ? 0.96 : 1.0)
            .offset(y: pressed ? 2 : 0)
            .shadow(
                color: CotabbyBrand.accent.opacity(pressed ? 0.1 : 0.25),
                radius: pressed ? 6 : 14,
                y: pressed ? 2 : 6
            )
            .task(id: reduceMotion) {
                guard !reduceMotion else {
                    pressed = false
                    return
                }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_300_000_000)
                    if Task.isCancelled { return }
                    withAnimation(.easeIn(duration: 0.1)) { pressed = true }
                    try? await Task.sleep(nanoseconds: 160_000_000)
                    if Task.isCancelled { return }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) { pressed = false }
                }
            }
            .accessibilityHidden(true)
    }
}
