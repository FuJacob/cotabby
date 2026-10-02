import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Apps pane: every app Cotabby knows about, most-used first, and a detail screen per app.
///
/// An app appears once anything is known about it: typing history was collected there, it is
/// disabled, or it has its own keys or behavior (`AppSettingsList`). Selecting one shows
/// `AppSettingsDetailView`. The list replaces the old separate "Per-App Shortcuts" and "Disabled
/// Apps" sections, whose settings now live on each app's detail screen.
struct AppsPaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    /// Owned by `CotabbyAppEnvironment`; supplies per-app input counts, exclusions, and deletion.
    @ObservedObject var typingHistory: TypingHistoryStore

    /// Snapshotted at view-appear time. We deliberately don't subscribe to NSWorkspace launch
    /// notifications: the panel is not a live process inspector, and re-rendering as random apps
    /// open and close would make the chips flicker while the user is mid-task.
    @State private var runningAppSuggestions: [RunningAppSuggestion] = []
    @State private var selectedApp: AppSettingsEntry?
    @State private var searchText = ""
    /// Apps added with "Add App…" that have no settings yet, so they stay listed this session.
    @State private var addedBundleIdentifiers: [String] = []

    var body: some View {
        SettingsPaneScaffold {
            if let selectedApp {
                AppSettingsDetailView(
                    suggestionSettings: suggestionSettings,
                    typingHistory: typingHistory,
                    bundleIdentifier: selectedApp.bundleIdentifier,
                    displayName: selectedApp.displayName,
                    onBack: { self.selectedApp = nil }
                )
            } else {
                appListSection
                integratedTerminalsSection
                runningAppsSection
            }
        }
        .onAppear {
            runningAppSuggestions = RunningAppSuggestion.collect()
        }
    }

    // MARK: - App list

    private var entries: [AppSettingsEntry] {
        AppSettingsList.entries(
            inputCounts: typingHistory.recordCountsByApp,
            disabledRules: suggestionSettings.disabledAppRules,
            overrides: suggestionSettings.perAppShortcutOverrides,
            excludedFromHistory: typingHistory.preferences.excludedBundleIdentifiers,
            addedBundleIdentifiers: addedBundleIdentifiers,
            displayName: AppIconCache.displayName(for:)
        )
    }

    private var appListSection: some View {
        Section("Apps") {
            Text("Choose an app to change how Cotabby behaves there: completions, mid-line suggestions, " +
                "autocorrect, accept keys, instructions, and typing history.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .settingsItem(.disabledApps)

            HStack(spacing: 8) {
                TextField("Search apps", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Button("Add App…") { presentAppPicker() }
            }

            let visible = AppSettingsList.filter(entries, query: searchText)
            if visible.isEmpty {
                Text(searchText.isEmpty
                    ? "No apps yet. Apps appear here once you type in them with typing history on, or add one."
                    : "No apps match “\(searchText)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visible) { entry in
                    appRow(entry)
                }
            }
        }
    }

    @ViewBuilder
    private func appRow(_ entry: AppSettingsEntry) -> some View {
        Button {
            selectedApp = entry
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: AppIconCache.icon(for: entry.bundleIdentifier))
                    .resizable()
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                Text(entry.displayName)
                if entry.isDisabled {
                    Image(systemName: "nosign")
                        .foregroundStyle(.secondary)
                        .help("Completions are off in this app.")
                        .accessibilityLabel("Completions off")
                }
                if entry.hasOverrides {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.secondary)
                        .help("This app has its own settings.")
                        .accessibilityLabel("Has its own settings")
                }
                Spacer(minLength: 0)
                if entry.inputCount > 0 {
                    Text("\(entry.inputCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("Typing-history inputs collected in this app.")
                }
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func presentAppPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Add"
        panel.message = "Choose an app to configure."
        guard panel.runModal() == .OK, let url = panel.url,
              let metadata = ApplicationBundleMetadata(appURL: url)
        else { return }
        if !addedBundleIdentifiers.contains(metadata.bundleIdentifier) {
            addedBundleIdentifiers.append(metadata.bundleIdentifier)
        }
        selectedApp = entries.first { $0.bundleIdentifier == metadata.bundleIdentifier }
            ?? AppSettingsEntry(
                bundleIdentifier: metadata.bundleIdentifier, displayName: metadata.displayName, inputCount: 0,
                isDisabled: false, hasOverrides: false, isExcludedFromHistory: false
            )
    }

    // MARK: - Global app settings

    private var integratedTerminalsSection: some View {
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
    }

    @ViewBuilder
    private var runningAppsSection: some View {
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
