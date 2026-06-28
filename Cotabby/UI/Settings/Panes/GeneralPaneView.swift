import LaunchAtLogin
import SwiftUI

/// File overview:
/// "General" detail pane: the top-level on/off switches and the core behavior toggles a user
/// reaches for most. How suggestions look moved to the Appearance pane and the emoji feature to the
/// Emoji pane, which keeps this pane short and scannable. Each row carries a leading SF Symbol via
/// `SettingsRowLabel` so the list reads at a glance.
struct GeneralPaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var permissionManager: PermissionManager
    let onShowWelcome: () -> Void

    /// Gates the destructive reset behind an explicit confirmation so a stray click can't wipe a
    /// user's entire configuration.
    @State private var isShowingResetConfirmation = false

    var body: some View {
        SettingsPaneScaffold {
            Section("Status") {
                Toggle(isOn: globallyEnabledBinding) {
                    SettingsRowLabel(
                        title: "Enable Globally",
                        description: "Turn Cotabby off everywhere without quitting the app.",
                        systemImage: "power"
                    )
                }
                .settingsItem(.enableGlobally)

                Toggle(isOn: fastModeForcedOn ? .constant(true) : fastModeEnabledBinding) {
                    SettingsRowLabel(
                        title: "Fast Mode",
                        description: fastModeDescription,
                        systemImage: "bolt.fill"
                    )
                }
                .disabled(fastModeForcedOn)
                .settingsItem(.fastMode)

                // Backed by `SMAppService.mainApp` via the LaunchAtLogin package, which owns the
                // observable for the login-item status and refreshes the toggle if the user changes
                // it in System Settings while Cotabby is open.
                LaunchAtLogin.Toggle {
                    SettingsRowLabel(
                        title: "Open at Login",
                        description: "Start Cotabby automatically when you log in to your Mac.",
                        systemImage: "arrow.right.circle"
                    )
                }
                .settingsItem(.openAtLogin)
            }

            // Split from the old catch-all "Behavior" group: what the model is allowed to read
            // (Context) reads differently from what a suggestion may contain (Suggestions). The
            // acceptance toggles that used to live here now sit with Writing, next to the other
            // controls that shape inserted text.
            Section("Context") {
                Toggle(isOn: clipboardContextEnabledBinding) {
                    SettingsRowLabel(
                        title: "Include Clipboard Context",
                        description: "Let suggestions reference whatever you most recently copied.",
                        systemImage: "doc.on.clipboard"
                    )
                }
                .settingsItem(.includeClipboardContext)

                Toggle(isOn: surfaceContextEnabledBinding) {
                    SettingsRowLabel(
                        title: "Include App Context",
                        description: "Let suggestions know which app and window you are typing in. Everything stays on this Mac.",
                        systemImage: "macwindow"
                    )
                }
                .settingsItem(.includeAppContext)
            }

            Section("Suggestions") {
                Toggle(isOn: multiLineEnabledBinding) {
                    SettingsRowLabel(
                        title: "Allow Multi-line Suggestions",
                        description: "Allow continuations that span more than one line. Off keeps suggestions to a single line.",
                        systemImage: "text.alignleft"
                    )
                }
                .settingsItem(.allowMultiLine)

                Toggle(isOn: macroExpansionEnabledBinding) {
                    SettingsRowLabel(
                        title: "Inline Macros",
                        description: "Type / then a macro: dates (today, tmrw, next-fri), math (5+5=), " +
                            "units (10km to mi), currency ($100 to eur), or random (dice, random(1,6)). " +
                            "Then press your accept-word shortcut to insert the result.",
                        systemImage: "slash.circle"
                    )
                }
                .settingsItem(.inlineMacros)
            }

            Section("Help") {
                LabeledContent {
                    Button("Open Welcome Guide") {
                        onShowWelcome()
                    }
                } label: {
                    SettingsRowLabel(
                        title: "Onboarding",
                        description: "Replay the first-run setup walkthrough.",
                        systemImage: "graduationcap"
                    )
                }
                .settingsItem(.onboarding)
            }

            Section("Reset") {
                LabeledContent {
                    Button("Reset All Settings…", role: .destructive) {
                        isShowingResetConfirmation = true
                    }
                } label: {
                    SettingsRowLabel(
                        title: "Reset All Settings",
                        description: "Restore every Cotabby setting to its original default. This does not change " +
                            "macOS permissions, your Open at Login choice, or your accepted-word count.",
                        systemImage: "arrow.counterclockwise"
                    )
                }
                .settingsItem(.resetAllSettings)
            }
        }
        .confirmationDialog(
            "Reset all settings to their defaults?",
            isPresented: $isShowingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset All Settings", role: .destructive) {
                suggestionSettings.resetToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every Cotabby setting returns to its original default. This can't be undone.")
        }
    }

    // MARK: - Bindings

    private var globallyEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isGloballyEnabled },
            set: { suggestionSettings.setGloballyEnabled($0) }
        )
    }

    private var clipboardContextEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isClipboardContextEnabled },
            set: { suggestionSettings.setClipboardContextEnabled($0) }
        )
    }

    private var surfaceContextEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isSurfaceContextEnabled },
            set: { suggestionSettings.setSurfaceContextEnabled($0) }
        )
    }

    private var fastModeEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isFastModeEnabled },
            set: { suggestionSettings.setFastModeEnabled($0) }
        )
    }

    /// Fast Mode is forced on and locked while Screen Recording is unavailable (visual context can't
    /// run without it). The stored preference is left untouched so it returns when the permission is
    /// granted.
    private var fastModeForcedOn: Bool {
        !permissionManager.screenRecordingGranted
    }

    private var fastModeDescription: String {
        if fastModeForcedOn {
            return "Forced on because Screen Recording is off. Suggestions rely only on the text " +
                "you've typed; grant Screen Recording to add visual context."
        }
        return "Skip the screenshot-based context step for faster suggestions. " +
            "Suggestions rely only on the text you've typed."
    }

    private var multiLineEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isMultiLineEnabled },
            set: { suggestionSettings.setMultiLineEnabled($0) }
        )
    }

    private var macroExpansionEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isMacroExpansionEnabled },
            set: { suggestionSettings.setMacroExpansionEnabled($0) }
        )
    }
}
