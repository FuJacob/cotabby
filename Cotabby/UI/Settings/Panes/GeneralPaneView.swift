import LaunchAtLogin
import SwiftUI

/// File overview:
/// "General" detail pane: the top-level on/off switches and the core behavior toggles a user
/// reaches for most. How suggestions look moved to the Appearance pane and the emoji feature to the
/// Emoji pane, which keeps this pane short and scannable. Each row carries a leading SF Symbol via
/// `SettingsRowLabel` so the list reads at a glance.
struct GeneralPaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    let onShowWelcome: () -> Void

    var body: some View {
        SettingsPaneScaffold {
            supportSection

            Section("Status") {
                Toggle(isOn: globallyEnabledBinding) {
                    SettingsRowLabel(
                        title: "Enable Globally",
                        description: "Turn Cotabby off everywhere without quitting the app.",
                        systemImage: "power"
                    )
                }

                Toggle(isOn: fastModeEnabledBinding) {
                    SettingsRowLabel(
                        title: "Fast Mode",
                        description: "Skip the screenshot-based context step for faster suggestions. " +
                            "Suggestions rely only on the text you've typed.",
                        systemImage: "bolt.fill"
                    )
                }

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
            }

            Section("Behavior") {
                Toggle(isOn: clipboardContextEnabledBinding) {
                    SettingsRowLabel(
                        title: "Include Clipboard Context",
                        description: "Let suggestions reference whatever you most recently copied.",
                        systemImage: "doc.on.clipboard"
                    )
                }

                Toggle(isOn: multiLineEnabledBinding) {
                    SettingsRowLabel(
                        title: "Allow Multi-line Suggestions",
                        description: "Allow continuations that span more than one line. Off keeps suggestions to a single line.",
                        systemImage: "text.alignleft"
                    )
                }

                Toggle(isOn: autoAcceptTrailingPunctuationBinding) {
                    SettingsRowLabel(
                        title: "Accept Punctuation With Word",
                        description: "When you accept a word, also accept the punctuation that follows it " +
                            "(commas, periods) so you don't have to type it.",
                        systemImage: "textformat.abc"
                    )
                }
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
            }

        }
    }

    // MARK: - Support

    /// Pinned at the top of General so the support pitch is the first thing in the pane. The action
    /// is a filled pill (white background, pink "heart Support" text) so it reads as a real button to
    /// tap rather than an easy-to-miss inline link.
    @ViewBuilder
    private var supportSection: some View {
        if let kofiURL = URL(string: "https://ko-fi.com/cotabby") {
            Section {
                LabeledContent {
                    Link(destination: kofiURL) {
                        Label("Support", systemImage: "heart.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.pink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                } label: {
                    SettingsRowLabel(
                        title: "Support Cotabby",
                        description: "Cotabby is free and open source. Tips help fund development.",
                        systemImage: "heart"
                    )
                }
            }
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

    private var fastModeEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isFastModeEnabled },
            set: { suggestionSettings.setFastModeEnabled($0) }
        )
    }

    private var multiLineEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isMultiLineEnabled },
            set: { suggestionSettings.setMultiLineEnabled($0) }
        )
    }

    private var autoAcceptTrailingPunctuationBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.autoAcceptTrailingPunctuation },
            set: { suggestionSettings.setAutoAcceptTrailingPunctuation($0) }
        )
    }
}
