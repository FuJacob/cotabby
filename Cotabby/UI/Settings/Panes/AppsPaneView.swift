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
    /// Which (bundle identifier, action) the user is currently re-recording. Single-value state
    /// rather than a per-row binding so only one recorder can be active at a time — pressing
    /// "Change" on a second row dismisses the first, matching the global Shortcuts pane.
    @State private var recordingTarget: RecordingTarget?

    var body: some View {
        SettingsPaneScaffold {
            Section("Per-App Shortcuts") {
                Text("Give a specific app its own accept key. Apps without an override use the "
                    + "global shortcut from the Shortcuts pane.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if suggestionSettings.perAppShortcutOverrides.isEmpty {
                    Text("No per-app shortcuts. Cotabby uses the global accept key everywhere.")
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
                .help("Remove this app's overrides. Cotabby will use the global accept keys here.")
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
                inheritsHelp: "Uses the global shortcut (\(suggestionSettings.fullAcceptanceKeyLabel)). "
                    + "Click Change to set a custom key for \(override.displayName)."
            )
        }
        .padding(.vertical, 4)
    }

    /// One (action) row inside one per-app override. Renders the resolved keycap (override or
    /// global), then either a Change button (no override yet) or the full KeybindRow chrome
    /// (override set, with Reset-to-global as the affordance for clearing back to inheritance).
    @ViewBuilder
    private func perAppBindingRow(
        override: PerAppShortcutOverride,
        action: ShortcutAction,
        title: String,
        inheritsHelp: String
    ) -> some View {
        let inherits = (action == .acceptWord && !override.hasAcceptOverride)
            || (action == .acceptEntireSuggestion && !override.hasFullAcceptOverride)
        let recordingBinding = recordingBinding(forBundleIdentifier: override.bundleIdentifier, action: action)
        let label = perAppBindingLabel(override: override, action: action)
        let keyCode = perAppBindingKeyCode(override: override, action: action)
        let modifiers = perAppBindingModifiers(override: override, action: action)

        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.callout)
                .frame(width: 180, alignment: .leading)

            if inherits {
                Text("Uses global (\(label))")
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
                }
            } else {
                KeybindRow(
                    label: label,
                    keyCode: keyCode,
                    modifiers: modifiers,
                    // No factory default for per-app rows — "Reset to global" is the meaningful
                    // gesture and is wired through `onClear` below. Passing the disabled sentinel
                    // here ensures the recorder's built-in Reset button never appears.
                    defaultKeyCode: SuggestionSettingsModel.disabledKeyCode,
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
                    onReset: nil,
                    onClear: { clearPerAppBinding(override: override, action: action) },
                    clearHelp: "Reset to global — \(override.displayName) will use the global "
                        + "shortcut again.",
                    conflictChecker: perAppConflictChecker(
                        bundleIdentifier: override.bundleIdentifier,
                        action: action
                    )
                )
            }
        }
    }

    private func recordingBinding(forBundleIdentifier bundleIdentifier: String, action: ShortcutAction) -> Binding<Bool> {
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

    private func perAppBindingLabel(override: PerAppShortcutOverride, action: ShortcutAction) -> String {
        switch action {
        case .acceptWord:
            return override.acceptKeyLabel ?? suggestionSettings.acceptanceKeyLabel
        case .acceptEntireSuggestion:
            return override.fullAcceptKeyLabel ?? suggestionSettings.fullAcceptanceKeyLabel
        case .toggleTabby:
            return suggestionSettings.globalToggleKeyLabel
        }
    }

    private func perAppBindingKeyCode(override: PerAppShortcutOverride, action: ShortcutAction) -> CGKeyCode {
        switch action {
        case .acceptWord:
            return override.acceptKeyCode ?? suggestionSettings.acceptanceKeyCode
        case .acceptEntireSuggestion:
            return override.fullAcceptKeyCode ?? suggestionSettings.fullAcceptanceKeyCode
        case .toggleTabby:
            return suggestionSettings.globalToggleKeyCode
        }
    }

    private func perAppBindingModifiers(
        override: PerAppShortcutOverride,
        action: ShortcutAction
    ) -> ShortcutModifierMask {
        switch action {
        case .acceptWord:
            return override.acceptKeyModifiers ?? suggestionSettings.acceptanceKeyModifiers
        case .acceptEntireSuggestion:
            return override.fullAcceptKeyModifiers ?? suggestionSettings.fullAcceptanceKeyModifiers
        case .toggleTabby:
            return suggestionSettings.globalToggleKeyModifiers
        }
    }

    private func applyPerAppBinding(
        override: PerAppShortcutOverride,
        action: ShortcutAction,
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
        case .toggleTabby:
            // Per-app toggle is not exposed in this UI; the global toggle is intentionally global
            // because its purpose is to disable Cotabby everywhere.
            break
        }
    }

    private func clearPerAppBinding(override: PerAppShortcutOverride, action: ShortcutAction) {
        switch action {
        case .acceptWord:
            suggestionSettings.clearPerAppAcceptKey(bundleIdentifier: override.bundleIdentifier)
        case .acceptEntireSuggestion:
            suggestionSettings.clearPerAppFullAcceptKey(bundleIdentifier: override.bundleIdentifier)
        case .toggleTabby:
            break
        }
    }

    private func perAppConflictChecker(
        bundleIdentifier: String,
        action: ShortcutAction
    ) -> (CGKeyCode, ShortcutModifierMask) -> String? {
        { keyCode, modifiers in
            suggestionSettings.conflictingPerAppShortcutName(
                forBundleIdentifier: bundleIdentifier,
                keyCode: keyCode,
                modifiers: modifiers,
                excluding: action
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
            // Seed with the current global accept key so the row shows up immediately as an
            // explicit override; the user can then re-bind it. Without this, an "Add App" with
            // no further action would produce an empty row that the sanitizer removes on next
            // launch — the user would think the add failed.
            suggestionSettings.setPerAppAcceptKey(
                bundleIdentifier: metadata.bundleIdentifier,
                displayName: metadata.displayName,
                keyCode: suggestionSettings.acceptanceKeyCode,
                modifiers: suggestionSettings.acceptanceKeyModifiers,
                label: suggestionSettings.acceptanceKeyLabel
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

/// Identifies which per-app row+action is currently capturing a keybind. Kept as a single State
/// value in the pane so opening one recorder dismisses any other (matches the Shortcuts pane).
private struct RecordingTarget: Equatable {
    let bundleIdentifier: String
    let action: ShortcutAction
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
