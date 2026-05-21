import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// File overview:
/// Renders Tabby's settings window as the canonical home for durable user preferences.
///
/// Why this file exists:
/// the menu bar panel is a quick-control surface, but durable settings should also exist in a
/// stable window the user can revisit later. This view intentionally does not own persistence or
/// side effects; it reads and mutates long-lived services created by the app environment.
struct SettingsView: View {
    let appUpdateManager: AppUpdateManager

    @ObservedObject var launchAtLoginService: LaunchAtLoginService
    @ObservedObject var permissionManager: PermissionManager
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var foundationModelAvailabilityService: FoundationModelAvailabilityService
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var modelDownloadManager: ModelDownloadManager

    let onShowWelcome: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    @State private var pendingDeletionModel: RuntimeModelOption?

    var body: some View {
        Form {
            settingsHeader
            updatesSection
            generalSection
            autocompleteSection
            disabledAppsSection
            profileSection
            permissionsSection
            localModelsSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 620, minHeight: 560)
        .onAppear {
            refreshAppleIntelligenceAvailabilityIfNeeded()
            launchAtLoginService.refresh()
            permissionManager.refresh()
        }
        .onChange(of: suggestionSettings.selectedEngine) { _, _ in
            pendingDeletionModel = nil
            refreshAppleIntelligenceAvailabilityIfNeeded()
        }
        .alert(
            "Delete Model?",
            isPresented: pendingDeletionAlertBinding,
            presenting: pendingDeletionModel
        ) { model in
            Button("Delete") {
                deleteModel(model)
            }

            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text("Remove \(model.displayName) from Tabby's local models folder?")
        }
    }

    @ViewBuilder
    private var settingsHeader: some View {
        Section {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06))

                    Image(systemName: "pawprint.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Tabby")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))

                    Text("Local AI Autocomplete")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var generalSection: some View {
        Section("General") {
            Toggle("Open at Login", isOn: launchAtLoginBinding)
                .disabled(!launchAtLoginService.state.canToggle)

            if let message = launchAtLoginMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(launchAtLoginMessageColor)
            }

            LabeledContent("Onboarding") {
                Button("Open Welcome Guide") {
                    onShowWelcome()
                }
            }
        }
    }

    @ViewBuilder
    private var autocompleteSection: some View {
        Section("Autocomplete") {
            Toggle("Enable Globally", isOn: globallyEnabledBinding)

            Toggle("Include Clipboard Context", isOn: clipboardContextEnabledBinding)

            Picker("Indicator", selection: selectedIndicatorModeBinding) {
                ForEach(ActivationIndicatorMode.allCases) { mode in
                    Text(mode.displayLabel)
                        .tag(mode)
                }
            }

            LabeledContent("Ghost Text Color") {
                HStack(spacing: 8) {
                    ColorPicker(
                        "Ghost Text Color",
                        selection: customSuggestionTextColorBinding,
                        supportsOpacity: false
                    )
                    .labelsHidden()

                    Button("Use Automatic") {
                        suggestionSettings.setCustomSuggestionTextColorHex(nil)
                    }
                    .disabled(suggestionSettings.customSuggestionTextColorHex == nil)
                }
            }

            Text(ghostTextColorDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Engine", selection: selectedEngineBinding) {
                ForEach(SuggestionEngineKind.allCases) { engine in
                    Text(engine.displayLabel)
                        .tag(engine)
                }
            }

            if suggestionSettings.selectedEngine == .appleIntelligence {
                LabeledContent("Availability") {
                    Text(foundationModelAvailabilityService.userVisibleMessage)
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("Runtime") {
                    Text(runtimeModel.state.summary)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Length", selection: selectedWordCountPresetBinding) {
                ForEach(SuggestionWordCountPreset.allCases) { preset in
                    Text(preset.displayLabel)
                        .tag(preset)
                }
            }
        }
    }

    @ViewBuilder
    private var disabledAppsSection: some View {
        Section("Disabled Apps") {
            if suggestionSettings.disabledAppRules.isEmpty {
                Text("No apps are disabled. Apps you turn off from the menu bar will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(suggestionSettings.disabledAppRules) { rule in
                    disabledAppRuleRow(rule)
                }
            }
        }
    }

    @ViewBuilder
    private var profileSection: some View {
        Section("Profile") {
            VStack(alignment: .leading, spacing: 16) {
                Text("This information is passed to the AI to help personalize your completions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.system(size: 13, weight: .medium))

                    TextField("What should tabby call you?", text: Binding(
                        get: { suggestionSettings.userName },
                        set: { suggestionSettings.setUserName($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                // TODO: Re-enable "Things you type often" once we validate the feature's value.
                // VStack(alignment: .leading, spacing: 6) {
                //     Text("Things you type often")
                //         .font(.system(size: 13, weight: .medium))
                //
                //     TagsInputView(
                //         tags: Binding(
                //             get: { suggestionSettings.userTags },
                //             set: { suggestionSettings.setUserTags($0) }
                //         ),
                //         placeholder: "Add tags (press Enter to add)"
                //     )
                // }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var permissionsSection: some View {
        Section("Permissions") {
            Text("Tabby needs Accessibility, Input Monitoring, and Screen Recording for autocomplete.")
                .font(.caption)
                .foregroundStyle(.secondary)

            settingsPermissionRow(
                title: "Accessibility",
                granted: permissionManager.accessibilityGranted,
                action: permissionManager.openAccessibilitySettings
            )

            settingsPermissionRow(
                title: "Input Monitoring",
                granted: permissionManager.inputMonitoringGranted,
                action: permissionManager.openInputMonitoringSettings
            )

            settingsPermissionRow(
                title: "Screen Recording",
                granted: permissionManager.screenRecordingGranted,
                action: permissionManager.openScreenRecordingSettings
            )
        }
    }

    @ViewBuilder
    private var localModelsSection: some View {
        Section("Local Models") {
            Text(localModelsDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            if runtimeModel.availableModels.isEmpty {
                Text("No local GGUF models found. Download one below or add your own model file.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Selected Model", selection: selectedModelBinding) {
                    ForEach(runtimeModel.availableModels) { model in
                        Text(model.displayName)
                            .tag(model.filename)
                    }
                }
            }

            DownloadableModelCatalogView(
                modelDownloadManager: modelDownloadManager,
                onRefreshModels: refreshModels
            )

            LabeledContent("Folder") {
                VStack(alignment: .trailing, spacing: 8) {
                    Text(modelDownloadManager.modelsDirectoryPath)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)

                    HStack(spacing: 8) {
                        Button("Open Folder") {
                            modelDownloadManager.openModelsDirectory()
                        }

                        Button("Refresh") {
                            refreshModels()
                        }
                    }
                }
            }

            if !runtimeModel.availableModels.isEmpty {
                Text("Installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(runtimeModel.availableModels) { model in
                    installedModelRow(model)
                }
            }
        }
    }

    @ViewBuilder
    private var updatesSection: some View {
        Section("Updates") {
            LabeledContent("Version", value: appVersionText)

            LabeledContent {
                Button("Check for Updates") {
                    appUpdateManager.checkForUpdates()
                }
            } label: {
                Text("Check GitHub Releases for updates.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func installedModelRow(_ model: RuntimeModelOption) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)

                if model.displayName != model.actualModelName {
                    Text(model.actualModelName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if model.filename == runtimeModel.selectedModelFilename {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            } else if modelDownloadManager.canDeleteModel(filename: model.filename) {
                Button {
                    pendingDeletionModel = model
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Delete \(model.displayName)")
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
            .help("Remove \(rule.displayName) from disabled apps")
        }
    }

    private func icon(for rule: DisabledApplicationRule) -> NSImage {
        // Bundle IDs are durable; app paths are not. Resolve the current app URL at render time so
        // Settings naturally picks up app updates, moves, or reinstalls without persisting UI cache.
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: rule.bundleIdentifier
        ) else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }

        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    @ViewBuilder
    private func settingsPermissionRow(
        title: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)

            Spacer(minLength: 0)

            Text(granted ? "Granted" : "Needs Access")
                .font(.caption.weight(.medium))
                .foregroundStyle(granted ? .green : .orange)

            if !granted {
                Button("Open Settings") {
                    action()
                }
                .controlSize(.small)
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginService.state.isEnabled },
            set: { enabled in
                launchAtLoginService.setEnabled(enabled)
            }
        )
    }

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

    private var selectedIndicatorModeBinding: Binding<ActivationIndicatorMode> {
        Binding(
            get: { suggestionSettings.selectedIndicatorMode },
            set: { mode in
                suggestionSettings.selectIndicatorMode(mode)
            }
        )
    }

    /// The color picker always needs a concrete color. When the user has not picked one yet we feed
    /// it the current automatic fallback so the control still previews something sensible. The first
    /// user interaction promotes that preview into a persisted custom color.
    private var customSuggestionTextColorBinding: Binding<Color> {
        Binding(
            get: {
                SuggestionTextColorCodec.color(
                    fromHex: suggestionSettings.customSuggestionTextColorHex)
                    ?? automaticGhostTextColor
            },
            set: { color in
                guard let nsColor = NSColor(color).usingColorSpace(.sRGB),
                    let hex = SuggestionTextColorCodec.hexString(from: nsColor)
                else {
                    return
                }

                suggestionSettings.setCustomSuggestionTextColorHex(hex)
            }
        )
    }

    private var selectedEngineBinding: Binding<SuggestionEngineKind> {
        Binding(
            get: { suggestionSettings.selectedEngine },
            set: { engine in
                suggestionSettings.selectEngine(engine)
            }
        )
    }

    private var selectedWordCountPresetBinding: Binding<SuggestionWordCountPreset> {
        Binding(
            get: { suggestionSettings.selectedWordCountPreset },
            set: { preset in
                suggestionSettings.selectWordCountPreset(preset)
            }
        )
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: {
                runtimeModel.selectedModelFilename
                    ?? runtimeModel.availableModels.first?.filename
                    ?? ""
            },
            set: { filename in
                Task {
                    await runtimeModel.selectModel(filename)
                }
            }
        )
    }

    private var automaticGhostTextColor: Color {
        colorScheme == .dark
            ? Color(red: 0.65, green: 0.65, blue: 0.65)
            : Color(red: 0.45, green: 0.45, blue: 0.45)
    }

    private var ghostTextColorDescription: String {
        if suggestionSettings.customSuggestionTextColorHex == nil {
            return "Automatic adapts to light and dark editors with Tabby's default subtle gray."
        }

        return "Custom ghost text color is active."
    }

    private var localModelsDescription: String {
        if suggestionSettings.selectedEngine == .llamaOpenSource {
            return "Download a model or add your own below. Models are stored locally on your Mac."
        }

        return "These models are used when Engine is set to Open Source."
    }

    private var launchAtLoginMessage: String? {
        if let lastErrorMessage = launchAtLoginService.lastErrorMessage {
            return lastErrorMessage
        }

        return launchAtLoginService.state.detail
    }

    private var launchAtLoginMessageColor: Color {
        if launchAtLoginService.lastErrorMessage != nil {
            return .red
        }

        if case .requiresApproval = launchAtLoginService.state {
            return .orange
        }

        return .secondary
    }

    /// The app bundle is the canonical source for human-facing version text.
    private var appVersionText: String {
        let shortVersion =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion, buildNumber) {
        case (let shortVersion?, let buildNumber?) where shortVersion != buildNumber:
            return "\(shortVersion) (\(buildNumber))"
        case (let shortVersion?, _):
            return shortVersion
        case (_, let buildNumber?):
            return buildNumber
        default:
            return "Unknown"
        }
    }

    /// SwiftUI's alert API wants a Boolean binding, while the view naturally tracks the model the
    /// user intends to delete. This adapter keeps the real source of truth expressive and still
    /// allows the standard confirmation alert API to drive presentation.
    private var pendingDeletionAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletionModel != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletionModel = nil
                }
            }
        )
    }

    private func deleteModel(_ model: RuntimeModelOption) {
        modelDownloadManager.deleteModel(filename: model.filename)
        runtimeModel.refreshAvailableModels()
        pendingDeletionModel = nil
    }

    private func refreshModels() {
        modelDownloadManager.refreshModelStates()
        runtimeModel.refreshAvailableModels()
    }

    private func refreshAppleIntelligenceAvailabilityIfNeeded() {
        guard suggestionSettings.selectedEngine == .appleIntelligence else {
            return
        }

        foundationModelAvailabilityService.refresh()
    }
}
