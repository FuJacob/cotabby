import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// File overview:
/// "Apps" detail pane of the redesigned Settings window. Lists every app where Cotabby is
/// disabled, lets the user remove individual rules, and offers a file-picker entry point for apps
/// that can't be reached from the menu-bar toggle (launchers like Raycast or Spotlight that
/// dismiss themselves the moment the menu bar is clicked). Lifted from the legacy
/// `SettingsView.appsSection` so behavior is preserved.
struct AppsPaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    var body: some View {
        SettingsPaneScaffold {
            Section("Apps") {
                Text("Cotabby won't autocomplete in these apps. Add an app you can't disable from the "
                    + "menu bar, like a launcher that closes the moment it loses focus.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if suggestionSettings.disabledAppRules.isEmpty {
                    Text("No apps are disabled. Cotabby is active in every supported field.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(suggestionSettings.disabledAppRules) { rule in
                        disabledAppRuleRow(rule)
                    }
                }

                Button("Add App…") {
                    presentDisabledAppPicker()
                }
            }
        }
    }

    @ViewBuilder
    private func disabledAppRuleRow(_ rule: DisabledApplicationRule) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: icon(for: rule))
                .resizable()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.displayName)

                Text(rule.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)

            Button {
                suggestionSettings.removeDisabledApplication(
                    bundleIdentifier: rule.bundleIdentifier
                )
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }

    /// Bundle IDs are durable; app paths are not. Resolve the current app URL at render time so
    /// Settings naturally picks up app updates, moves, or reinstalls without persisting UI cache.
    private func icon(for rule: DisabledApplicationRule) -> NSImage {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: rule.bundleIdentifier
        ) else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    /// Lets the user disable Cotabby in an app they can't reach from the menu bar. The menu-bar
    /// "Enable in <app>" switch only targets the frontmost app, so a launcher like Raycast or
    /// Spotlight (which dismisses itself the instant the menu bar is clicked) can never be turned
    /// off that way. An open panel names any installed app whether or not it is running.
    private func presentDisabledAppPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Disable"
        panel.message = "Choose apps where Cotabby should not autocomplete."

        guard panel.runModal() == .OK else {
            return
        }

        for url in panel.urls {
            guard let metadata = ApplicationBundleMetadata(appURL: url) else {
                continue
            }
            suggestionSettings.disableApplication(
                bundleIdentifier: metadata.bundleIdentifier,
                displayName: metadata.displayName
            )
        }
    }
}
