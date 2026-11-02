import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// App-specific settings for shortcut overrides, exclusions, code editors, terminals, and coding agents.
struct AppsPaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    /// Snapshotted at view-appear time. We deliberately don't subscribe to NSWorkspace launch
    /// notifications: the panel is not a live process inspector, and re-rendering as random apps
    /// open and close would make the chips flicker while the user is mid-task.
    @State private var runningAppSuggestions: [RunningAppSuggestion] = []
    /// A single target prevents multiple key recorders from running at once.
    @State private var recordingTarget: RecordingTarget?

    var body: some View {
        SettingsPaneScaffold {
            Section("Per-App Shortcuts") {
                Text("Give a specific app its own accept key, disable an accept action there, or "
                    + "keep inheriting the global shortcut from the Shortcuts pane.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if suggestionSettings.perAppShortcutOverrides.isEmpty {
                    Text("No per-app shortcuts. Ghostype uses the global accept key everywhere.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(suggestionSettings.perAppShortcutOverrides) { override in
                        perAppOverrideRow(override)
                    }
                }

                Button("Add App…") {
                    presentPerAppOverridePicker()
                }
            }

            Section("Disabled Apps") {
                Text("Ghostype won't autocomplete in these apps. Add an app you can't disable from the "
                    + "menu bar, like a launcher that closes the moment it loses focus.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .settingsItem(.disabledApps)

                if suggestionSettings.disabledAppRules.isEmpty {
                    Text("No apps are disabled. Ghostype is active in every supported field.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(suggestionSettings.disabledAppRules) { rule in
                        appRuleRow(rule) {
                            suggestionSettings.removeDisabledApplication(bundleIdentifier: rule.bundleIdentifier)
                        }
                    }
                }

                Button("Add App…") {
                    presentDisabledAppPicker()
                }
            }

            Section("Code Editors") {
                Text("Ghostype won't complete in the code editor of these apps (VS Code, Cursor, Windsurf). "
                    + "Their chat, commit message, and other fields keep suggesting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .settingsItem(.completeInCodeEditors)

                if suggestionSettings.codeEditorDisabledAppRules.isEmpty {
                    Text("Every app completes in its code editor.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(suggestionSettings.codeEditorDisabledAppRules) { rule in
                        appRuleRow(rule) {
                            suggestionSettings.setCodeEditorCompletionEnabled(
                                bundleIdentifier: rule.bundleIdentifier,
                                displayName: rule.displayName,
                                enabled: true
                            )
                        }
                    }
                }

                Button("Add App…") {
                    presentAppPicker(
                        prompt: "Add",
                        message: "Choose apps that should not complete in their code editor."
                    ) { metadata in
                        suggestionSettings.setCodeEditorCompletionEnabled(
                            bundleIdentifier: metadata.bundleIdentifier,
                            displayName: metadata.displayName,
                            enabled: false
                        )
                    }
                }
            }

            Section("Terminals") {
                Toggle(isOn: completeInCodingAgentsBinding) {
                    SettingsRowLabel(
                        title: "Complete in Coding Agents",
                        description: "Show ghost text while you write to Claude Code, Codex, or Copilot CLI in "
                            + "Terminal, iTerm2, or another terminal, tmux included. Only the agent's input box "
                            + "is completed; a shell prompt never is.",
                        systemImage: "apple.terminal"
                    )
                }
                .settingsItem(.completeInCodingAgents)

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

    private var completeInCodingAgentsBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.completeInCodingAgents },
            set: { suggestionSettings.setCompleteInCodingAgents($0) }
        )
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
    private func perAppOverrideRow(_ override: PerAppShortcutOverride) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(nsImage: icon(forBundleIdentifier: override.bundleIdentifier))
                    .resizable()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(override.displayName)
                    Text(override.bundleIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 0)

                Button {
                    suggestionSettings.removePerAppOverride(bundleIdentifier: override.bundleIdentifier)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove per-app shortcuts for \(override.displayName)")
                .help("Remove this app's overrides. Ghostype will use the global accept keys here.")
            }

            perAppBindingRow(
                override: override,
                action: .acceptWord,
                title: "Accept Word",
                inheritsHelp: "Uses the global shortcut (\(suggestionSettings.acceptanceKeyLabel)). "
                    + "Click Change to set a custom key for \(override.displayName)."
            )
            perAppBindingRow(
                override: override,
                action: .acceptEntireSuggestion,
                title: "Accept Entire Suggestion",
                inheritsHelp: "Uses the global shortcut ("
                    + "\(suggestionSettings.inheritedFullAcceptanceDisplayLabel(forBundleIdentifier: override.bundleIdentifier))). "
                    + "Click Change to set a custom key for \(override.displayName)."
            )
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func perAppBindingRow(
        override: PerAppShortcutOverride,
        action: PerAppShortcutAction,
        title: String,
        inheritsHelp: String
    ) -> some View {
        let inherits = (action == .acceptWord && override.acceptance == nil)
            || (action == .acceptEntireSuggestion && override.fullAcceptance == nil)
        let recordingBinding = recordingBinding(forBundleIdentifier: override.bundleIdentifier, action: action)
        let binding = perAppBinding(override: override, action: action)

        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.callout)
                .frame(width: 180, alignment: .leading)

            if inherits {
                Text("Uses global (\(inheritedLabel(override: override, action: action, binding: binding)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(inheritsHelp)

                if recordingBinding.wrappedValue {
                    KeyRecorderView(
                        onKeyRecorded: { keyCode, modifiers, recordedLabel in
                            applyPerAppBinding(
                                override: override,
                                action: action,
                                keyCode: keyCode,
                                modifiers: modifiers,
                                label: recordedLabel
                            )
                            recordingTarget = nil
                        },
                        onCancelled: { recordingTarget = nil },
                        conflictChecker: perAppConflictChecker(
                            bundleIdentifier: override.bundleIdentifier,
                            action: action
                        )
                    )
                } else {
                    Button("Change") {
                        recordingTarget = RecordingTarget(
                            bundleIdentifier: override.bundleIdentifier,
                            action: action
                        )
                    }

                    Button("Disable") {
                        disablePerAppBinding(override: override, action: action)
                    }
                    .help("No key will perform \(title.lowercased()) in \(override.displayName).")
                }
            } else {
                KeybindRow(
                    label: binding.label,
                    keyCode: binding.keyCode,
                    isRecording: recordingBinding,
                    onRecord: { keyCode, modifiers, recordedLabel in
                        applyPerAppBinding(
                            override: override,
                            action: action,
                            keyCode: keyCode,
                            modifiers: modifiers,
                            label: recordedLabel
                        )
                    },
                    onReset: { clearPerAppBinding(override: override, action: action) },
                    resetLabel: "Use Global",
                    shouldShowReset: true,
                    onClear: { disablePerAppBinding(override: override, action: action) },
                    clearLabel: "Disable",
                    clearHelp: "No key will perform \(title.lowercased()) in \(override.displayName).",
                    conflictChecker: perAppConflictChecker(
                        bundleIdentifier: override.bundleIdentifier,
                        action: action
                    )
                )
            }
        }
    }

    /// The inherited shortcut as this app sees it; for full acceptance that may be a double tap.
    private func inheritedLabel(
        override: PerAppShortcutOverride,
        action: PerAppShortcutAction,
        binding: ShortcutResolver.ResolvedBinding
    ) -> String {
        guard action == .acceptEntireSuggestion else { return binding.label }
        return suggestionSettings.inheritedFullAcceptanceDisplayLabel(forBundleIdentifier: override.bundleIdentifier)
    }

    private func recordingBinding(
        forBundleIdentifier bundleIdentifier: String,
        action: PerAppShortcutAction
    ) -> Binding<Bool> {
        Binding(
            get: {
                recordingTarget == RecordingTarget(bundleIdentifier: bundleIdentifier, action: action)
            },
            set: { isRecording in
                if isRecording {
                    recordingTarget = RecordingTarget(bundleIdentifier: bundleIdentifier, action: action)
                } else if recordingTarget == RecordingTarget(bundleIdentifier: bundleIdentifier, action: action) {
                    recordingTarget = nil
                }
            }
        )
    }

    private func perAppBinding(
        override: PerAppShortcutOverride,
        action: PerAppShortcutAction
    ) -> ShortcutResolver.ResolvedBinding {
        switch action {
        case .acceptWord:
            return suggestionSettings.resolvedAcceptBinding(
                forBundleIdentifier: override.bundleIdentifier
            )
        case .acceptEntireSuggestion:
            return suggestionSettings.resolvedFullAcceptBinding(
                forBundleIdentifier: override.bundleIdentifier
            )
        }
    }

    private func applyPerAppBinding(
        override: PerAppShortcutOverride,
        action: PerAppShortcutAction,
        keyCode: CGKeyCode,
        modifiers: ShortcutModifierMask,
        label: String
    ) {
        switch action {
        case .acceptWord:
            suggestionSettings.setPerAppAcceptKey(
                bundleIdentifier: override.bundleIdentifier,
                displayName: override.displayName,
                keyCode: keyCode,
                modifiers: modifiers,
                label: label
            )
        case .acceptEntireSuggestion:
            suggestionSettings.setPerAppFullAcceptKey(
                bundleIdentifier: override.bundleIdentifier,
                displayName: override.displayName,
                keyCode: keyCode,
                modifiers: modifiers,
                label: label
            )
        }
    }

    private func clearPerAppBinding(
        override: PerAppShortcutOverride,
        action: PerAppShortcutAction
    ) {
        switch action {
        case .acceptWord:
            suggestionSettings.clearPerAppAcceptKey(bundleIdentifier: override.bundleIdentifier)
        case .acceptEntireSuggestion:
            suggestionSettings.clearPerAppFullAcceptKey(bundleIdentifier: override.bundleIdentifier)
        }
    }

    private func disablePerAppBinding(
        override: PerAppShortcutOverride,
        action: PerAppShortcutAction
    ) {
        applyPerAppBinding(
            override: override,
            action: action,
            keyCode: SuggestionSettingsModel.disabledKeyCode,
            modifiers: [],
            label: SuggestionSettingsModel.disabledKeyLabel
        )
    }

    private func perAppConflictChecker(
        bundleIdentifier: String,
        action: PerAppShortcutAction
    ) -> (CGKeyCode, ShortcutModifierMask) -> String? {
        { keyCode, modifiers in
            suggestionSettings.conflictingPerAppShortcutName(
                forBundleIdentifier: bundleIdentifier,
                keyCode: keyCode,
                modifiers: modifiers,
                excluding: action.shortcutAction
            )
        }
    }

    private func presentPerAppOverridePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Add"
        panel.message = "Choose apps that should get their own accept shortcut."

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            guard let metadata = ApplicationBundleMetadata(appURL: url) else { continue }
            suggestionSettings.addPerAppShortcutApp(
                bundleIdentifier: metadata.bundleIdentifier,
                displayName: metadata.displayName
            )
        }
    }

    private func icon(forBundleIdentifier bundleIdentifier: String) -> NSImage {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    @ViewBuilder
    private func appRuleRow(_ rule: DisabledApplicationRule, onRemove: @escaping () -> Void) -> some View {
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

            Button(action: onRemove) {
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

    /// Lets the user disable Ghostype in an app they can't reach from the menu bar. The menu-bar
    /// "Enable in <app>" switch only targets the frontmost app, so a launcher like Raycast or
    /// Spotlight (which dismisses itself the instant the menu bar is clicked) can never be turned
    /// off that way. An open panel names any installed app whether or not it is running.
    private func presentDisabledAppPicker() {
        presentAppPicker(prompt: "Disable", message: "Choose apps where Ghostype should not autocomplete.") { metadata in
            suggestionSettings.disableApplication(
                bundleIdentifier: metadata.bundleIdentifier,
                displayName: metadata.displayName
            )
        }
    }

    /// Shared app chooser for the per-app lists: hands each chosen app's bundle metadata to `add`.
    private func presentAppPicker(
        prompt: String,
        message: String,
        add: (ApplicationBundleMetadata) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = prompt
        panel.message = message

        guard panel.runModal() == .OK else {
            return
        }

        for url in panel.urls {
            guard let metadata = ApplicationBundleMetadata(appURL: url) else {
                continue
            }
            add(metadata)
        }
    }
}

/// Identifies the only per-app key recorder allowed to be active.
private struct RecordingTarget: Equatable {
    let bundleIdentifier: String
    let action: PerAppShortcutAction
}

private enum PerAppShortcutAction: Equatable {
    case acceptWord
    case acceptEntireSuggestion

    var shortcutAction: ShortcutAction {
        switch self {
        case .acceptWord: return .acceptWord
        case .acceptEntireSuggestion: return .acceptEntireSuggestion
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

    /// Snapshot the user-launched apps (`activationPolicy == .regular`) excluding Ghostype itself,
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
