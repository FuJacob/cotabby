import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// File overview:
/// Renders Cotabby's settings window as the canonical home for durable user preferences.
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
    @State private var isRecordingKeybind = false
    @State private var isRecordingFullAcceptKeybind = false

    var body: some View {
        Form {
            // Header keeps the app identity and the (important, frequently-checked) update
            // control pinned at the very top; Support stays directly beneath it.
            settingsHeader
            supportSection
            // Surfaces broken state (missing permission / unavailable engine) high up so the
            // user doesn't have to scroll to discover why autocomplete isn't working.
            attentionBanner
            generalSection
            modelEngineSection
            writingSection
            shortcutsSection
            // performanceSection — hidden until these controls are productized.
            // Both suggestion delay and focus poll interval are developer-facing
            // tuning knobs that invite misconfiguration for end users.
            appsSection
            permissionsSection
            uninstallSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 620, minHeight: 560)
        .onAppear {
            launchAtLoginService.refresh()
            permissionManager.refresh()
        }
        .onChange(of: suggestionSettings.selectedEngine) { _, _ in
            pendingDeletionModel = nil
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
            Text("Remove \(model.displayName) from Cotabby's local models folder?")
        }
    }

    @ViewBuilder
    private var settingsHeader: some View {
        Section {
            HStack(spacing: 10) {
                Image("CotabbyLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text("Cotabby")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))

                    Text("Local macOS AI Autocomplete")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                // Updates are important enough to stay visible without scrolling, but compact
                // enough to ride along in the title bar instead of owning a whole section.
                VStack(alignment: .trailing, spacing: 4) {
                    Text(appVersionText)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)

                    Button("Check for Updates") {
                        appUpdateManager.checkForUpdates()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    /// Conditional banner that only renders when something is preventing autocomplete from
    /// working. Detailed remediation still lives in the Permissions / Model sections below;
    /// this just makes the problem impossible to miss.
    @ViewBuilder
    private var attentionBanner: some View {
        if !permissionManager.requiredPermissionsGranted {
            attentionRow("Cotabby needs more access to run. See Permissions below to grant it.")
        } else if suggestionSettings.selectedEngine == .appleIntelligence,
                  !foundationModelAvailabilityService.isAvailable {
            attentionRow(foundationModelAvailabilityService.userVisibleMessage)
        } else if suggestionSettings.selectedEngine == .llamaOpenSource,
                  case .failed(let detail) = runtimeModel.state {
            attentionRow("\(detail) See Model & Engine below.")
        }
    }

    @ViewBuilder
    private func attentionRow(_ message: String) -> some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Everyday on/off behavior the user reaches for most often, plus the onboarding re-entry.
    @ViewBuilder
    private var generalSection: some View {
        Section("General") {
            Toggle("Enable Globally", isOn: globallyEnabledBinding)

            Toggle("Show Indicator", isOn: showIndicatorBinding)

            Toggle("Allow Multi-line Suggestions", isOn: multiLineEnabledBinding)

            Toggle("Include Clipboard Context", isOn: clipboardContextEnabledBinding)

            // Open at Login is hidden until the quarantine/SMAppService issue is resolved.
            // The toggle reports .notFound for quarantined apps and apps outside /Applications,
            // making it appear broken for most users. See LaunchAtLoginService for details.

            LabeledContent("Onboarding") {
                Button("Open Welcome Guide") {
                    onShowWelcome()
                }
            }
        }
    }

    /// Which brain runs (engine + availability) and the local model files it uses. Merged so the
    /// engine choice and the models that back it are no longer separated by unrelated sections.
    @ViewBuilder
    private var modelEngineSection: some View {
        Section("Model & Engine") {
            Picker("Engine", selection: selectedEngineBinding) {
                ForEach(SuggestionEngineKind.allCases) { engine in
                    Text(engine.displayLabel)
                        .tag(engine)
                }
            }

            switch suggestionSettings.selectedEngine {
            case .appleIntelligence:
                LabeledContent("Availability") {
                    Text(foundationModelAvailabilityService.userVisibleMessage)
                        .foregroundStyle(.secondary)
                }
            case .llamaOpenSource:
                LabeledContent("Runtime") {
                    Text(runtimeModel.state.summary)
                        .foregroundStyle(.secondary)
                }
            }

            if suggestionSettings.selectedEngine.supportsLocalModelManagement {
                localModelControls
            }
        }
    }

    /// How the completion reads: length, language, custom directives, and who the user is.
    @ViewBuilder
    private var writingSection: some View {
        Section("Writing") {
            Picker("Length", selection: selectedWordCountPresetBinding) {
                ForEach(SuggestionWordCountPreset.allCases) { preset in
                    Text(preset.displayLabel)
                        .tag(preset)
                }
            }

            Picker("Language", selection: selectedLanguageBinding) {
                ForEach(SuggestionLanguage.allCases) { language in
                    Text(language.displayLabel)
                        .tag(language)
                }
            }

            VStack(alignment: .leading, spacing: 24) {
                Text("This information is passed to the AI to help personalize your completions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Name")
                        .font(.system(size: 13, weight: .medium))

                    TextField("What should Cotabby call you?", text: Binding(
                        get: { suggestionSettings.userName },
                        set: { suggestionSettings.setUserName($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                CustomRulesEditor(suggestionSettings: suggestionSettings)
            }
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var shortcutsSection: some View {
        Section("Shortcuts") {
            LabeledContent("Accept Word") {
                HStack(spacing: 8) {
                    Text(suggestionSettings.acceptanceKeyLabel)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.quaternary)
                        )

                    if isRecordingKeybind {
                        KeyRecorderView(
                            onKeyRecorded: { keyCode, label in
                                suggestionSettings.setAcceptanceKey(keyCode: keyCode, label: label)
                                isRecordingKeybind = false
                            },
                            onCancelled: {
                                isRecordingKeybind = false
                            }
                        )
                    } else {
                        Button("Change") {
                            isRecordingKeybind = true
                        }
                    }

                    if suggestionSettings.acceptanceKeyCode != SuggestionSettingsModel.defaultAcceptanceKeyCode {
                        Button("Reset") {
                            suggestionSettings.setAcceptanceKey(
                                keyCode: SuggestionSettingsModel.defaultAcceptanceKeyCode,
                                label: SuggestionSettingsModel.defaultAcceptanceKeyLabel
                            )
                            isRecordingKeybind = false
                        }
                    }

                    if suggestionSettings.acceptanceKeyCode != SuggestionSettingsModel.disabledKeyCode {
                        Button("Clear") {
                            suggestionSettings.clearAcceptanceKey()
                            isRecordingKeybind = false
                        }
                    }
                }
            }

            LabeledContent("Accept Entire Suggestion") {
                HStack(spacing: 8) {
                    Text(suggestionSettings.fullAcceptanceKeyLabel)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.quaternary)
                        )

                    if isRecordingFullAcceptKeybind {
                        KeyRecorderView(
                            onKeyRecorded: { keyCode, label in
                                suggestionSettings.setFullAcceptanceKey(keyCode: keyCode, label: label)
                                isRecordingFullAcceptKeybind = false
                            },
                            onCancelled: {
                                isRecordingFullAcceptKeybind = false
                            }
                        )
                    } else {
                        Button("Change") {
                            isRecordingFullAcceptKeybind = true
                        }
                    }

                    if suggestionSettings.fullAcceptanceKeyCode != SuggestionSettingsModel.disabledKeyCode {
                        Button("Clear") {
                            suggestionSettings.clearFullAcceptanceKey()
                            isRecordingFullAcceptKeybind = false
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var performanceSection: some View {
        Section("Performance") {
            Stepper(
                "Suggestion Delay: \(suggestionSettings.debounceMilliseconds)ms",
                value: debounceMillisecondsBinding,
                in: 10...500,
                step: 10
            )

            Text("How long to wait after typing before generating a suggestion.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Focus poll interval is intentionally hidden from the UI. The default (50 ms)
            // is tuned for the best balance of responsiveness and CPU usage. Exposing it
            // invites misconfiguration without meaningful benefit. The backing setting and
            // UserDefaults plumbing remain so we can re-surface it later if needed.
        }
    }

    @ViewBuilder
    private var appsSection: some View {
        Section("Apps") {
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
    private var permissionsSection: some View {
        Section("Permissions") {
            Text("Cotabby needs Accessibility, Input Monitoring, and Screen Recording for autocomplete.")
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

    /// Local model rows nested inside the Model & Engine section (no `Section` wrapper of its
    /// own). Only shown for engines that manage local GGUF files.
    @ViewBuilder
    private var localModelControls: some View {
        Group {
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
                        let lmStudioURL = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".lmstudio/models")
                        let isUsingCustomPath = BundledRuntimeLocator.customModelDirectoryURL() != nil
                        Button("Use LM Studio") {
                            BundledRuntimeLocator.setCustomModelDirectory(lmStudioURL)
                            modelDownloadManager.refreshSearchDirectories()
                            refreshModels()
                        }
                        .disabled(
                            !FileManager.default.fileExists(atPath: lmStudioURL.path)
                        )

                        Button("Reset Path") {
                            BundledRuntimeLocator.setCustomModelDirectory(nil)
                            modelDownloadManager.refreshSearchDirectories()
                            refreshModels()
                        }
                        .disabled(!isUsingCustomPath)

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
    private var supportSection: some View {
        Section("Support") {
            LabeledContent {
                Link(destination: URL(string: "https://ko-fi.com/cotabby")!) {
                    Text("Buy Us a Coffee")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            } label: {
                Text(
                    "Cotabby is free and open source, maintained by two university students. "
                    + "If it's useful to you, consider supporting development."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var uninstallSection: some View {
        Section("Uninstall") {
            Text(
                "Drag Cotabby.app from Applications to the Trash. "
                + "To remove leftover data, also delete ~/Library/Application Support/Cotabby. "
                + "Privacy permissions can only be revoked in System Settings → Privacy & Security."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private var showIndicatorBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.showIndicator },
            set: { suggestionSettings.setShowIndicator($0) }
        )
    }

    private var multiLineEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isMultiLineEnabled },
            set: { suggestionSettings.setMultiLineEnabled($0) }
        )
    }

    private var debounceMillisecondsBinding: Binding<Int> {
        Binding(
            get: { suggestionSettings.debounceMilliseconds },
            set: { suggestionSettings.setDebounceMilliseconds($0) }
        )
    }

    // focusPollIntervalMillisecondsBinding removed — the poll interval stepper is hidden from
    // the UI (see performanceSection). Binding kept commented for easy restoration:
    //
    // private var focusPollIntervalMillisecondsBinding: Binding<Int> {
    //     Binding(
    //         get: { suggestionSettings.focusPollIntervalMilliseconds },
    //         set: { suggestionSettings.setFocusPollIntervalMilliseconds($0) }
    //     )
    // }

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

    private var selectedLanguageBinding: Binding<SuggestionLanguage> {
        Binding(
            get: { suggestionSettings.responseLanguage },
            set: { language in
                suggestionSettings.setResponseLanguage(language)
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
            return "Automatic adapts to light and dark editors with Cotabby's default subtle gray."
        }

        return "Custom ghost text color is active."
    }

    private var localModelsDescription: String {
        switch suggestionSettings.selectedEngine {
        case .llamaOpenSource:
            return "Download a model or add your own below. Models are stored locally on your Mac."
        case .appleIntelligence:
            return "These models are used when Engine is set to Open Source."
        }
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

}
