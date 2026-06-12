import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// File overview:
/// "Apps" detail pane of the redesigned Settings window. Lists every app where Cotabby is
/// disabled, lets the user remove individual rules, and offers a file-picker entry point for apps
/// that can't be reached from the menu-bar toggle (launchers like Raycast or Spotlight that
/// dismiss themselves the moment the menu bar is clicked).
struct AppsPaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    /// Snapshotted at view-appear time. We deliberately don't subscribe to NSWorkspace launch
    /// notifications: the panel is not a live process inspector, and re-rendering as random apps
    /// open and close would make the chips flicker while the user is mid-task.
    @State private var runningAppSuggestions: [RunningAppSuggestion] = []

    var body: some View {
        SettingsPaneScaffold {
            Section("Disabled Apps") {
                Text("Cotabby won't autocomplete in these apps. Add an app you can't disable from the "
                    + "menu bar, like a launcher that closes the moment it loses focus.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .settingsItem(.disabledApps)

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

            Section("Integrated Terminals") {
                Toggle(isOn: suggestInIntegratedTerminalsBinding) {
                    SettingsRowLabel(
                        title: "Suggest in Integrated Terminals",
                        description: "Show ghost text in VS Code and Cursor integrated terminals. "
                            + "Off by default so suggestions stay out of shell prompts; the editor "
                            + "and chat in the same window keep suggesting either way.",
                        systemImage: "terminal"
                    )
                }
                .settingsItem(.suggestInIntegratedTerminals)
            }

            if !filteredRunningAppSuggestions.isEmpty {
                Section("Suggestions") {
                    Text("Currently running apps you can disable with one click.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(filteredRunningAppSuggestions) { suggestion in
                            runningAppSuggestionRow(suggestion)
                        }
                    }
                }
            }
        }
        .onAppear {
            runningAppSuggestions = RunningAppSuggestion.collect()
        }
    }

    private var suggestInIntegratedTerminalsBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.suggestInIntegratedTerminals },
            set: { suggestionSettings.setSuggestInIntegratedTerminals($0) }
        )
    }

    /// Hide suggestions that are already in the disabled list so the row never shows a
    /// no-op chip. Recomputed on every redraw because `disabledAppRules` is observed.
    private var filteredRunningAppSuggestions: [RunningAppSuggestion] {
        let disabled = Set(suggestionSettings.disabledAppRules.map(\.bundleIdentifier))
        return runningAppSuggestions.filter { !disabled.contains($0.bundleIdentifier) }
    }

    @ViewBuilder
    private func runningAppSuggestionRow(_ suggestion: RunningAppSuggestion) -> some View {
        Button {
            suggestionSettings.disableApplication(
                bundleIdentifier: suggestion.bundleIdentifier,
                displayName: suggestion.displayName
            )
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: suggestion.icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)

                Text(suggestion.displayName)

                Spacer(minLength: 0)

                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

/// One disable-able app surfaced from the running-process list. Captures the icon up front so the
/// row doesn't have to hit NSWorkspace again on every redraw.
private struct RunningAppSuggestion: Identifiable {
    let bundleIdentifier: String
    let displayName: String
    let icon: NSImage

    var id: String { bundleIdentifier }

    /// Snapshot the user-launched apps (`activationPolicy == .regular`) excluding Cotabby itself,
    /// sorted alphabetically and capped at 8 so the section stays glanceable.
    static func collect() -> [RunningAppSuggestion] {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let candidates = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.bundleIdentifier != ownBundleIdentifier }

        var seen = Set<String>()
        let suggestions: [RunningAppSuggestion] = candidates.compactMap { app in
            guard let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty else {
                return nil
            }
            guard seen.insert(bundleIdentifier).inserted else { return nil }
            let displayName = app.localizedName ?? bundleIdentifier
            let icon = app.icon ?? NSWorkspace.shared.icon(for: .applicationBundle)
            return RunningAppSuggestion(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName,
                icon: icon
            )
        }
        return suggestions
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .prefix(8)
            .map { $0 }
    }
}
