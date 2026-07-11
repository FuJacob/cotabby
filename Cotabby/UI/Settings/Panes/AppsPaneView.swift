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

            Section("Terminal Autocomplete") {
                Toggle(isOn: suggestInIntegratedTerminalsBinding) {
                    SettingsRowLabel(
                        title: "Terminal Autocomplete (Beta)",
                        description: "Show source-verified ghost text in dedicated and integrated "
                            + "terminals. Shell prompts use a local hook; Claude Code uses on-device "
                            + "screen OCR. Off by default.",
                        systemImage: "terminal"
                    )
                }
                .settingsItem(.suggestInIntegratedTerminals)

                if suggestionSettings.suggestInIntegratedTerminals {
                    terminalSetupInstructions
                }
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

    /// The app installs signed hook copies under Application Support when the beta starts. Settings
    /// only presents explicit source commands—it never mutates a shell startup file behind the
    /// user's back, because ordering and existing plugin managers are shell-specific decisions.
    @ViewBuilder
    private var terminalSetupInstructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add the command for your shell to its startup file, then open a new terminal. "
                + "Screen Recording permission is used only to locate the visible prompt and read "
                + "Claude Code's input box; command text and OCR stay on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)

            terminalCommandRow(shell: .zsh, startupFile: "~/.zshrc")
            terminalCommandRow(shell: .bash, startupFile: "~/.bashrc (Bash 4+)")
            terminalCommandRow(shell: .fish, startupFile: "~/.config/fish/conf.d/cotabby.fish")

            Text("The Bash and fish hooks wrap printable-key bindings and may conflict with custom "
                + "line-editor bindings. zsh uses its non-invasive redraw hook and is recommended.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 28)
    }

    @ViewBuilder
    private func terminalCommandRow(shell: ShellType, startupFile: String) -> some View {
        let command = setupCommand(for: shell)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(shell.rawValue) · \(startupFile)")
                    .font(.caption.weight(.medium))
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy \(shell.rawValue) terminal setup command")
            }
            Text(command)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
        }
        .padding(8)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
    }

    private func setupCommand(for shell: ShellType) -> String {
        let paths = TerminalIntegrationPaths.current()
        let socket = shellQuoted(paths.socketURL.path)
        let hook = shellQuoted(paths.hookURL(for: shell).path)
        switch shell {
        case .zsh, .bash:
            return "export COTABBY_SOCKET_PATH=\(socket)\nsource \(hook)"
        case .fish:
            return "set -gx COTABBY_SOCKET_PATH \(socket)\nsource \(hook)"
        }
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
