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
    @ObservedObject var huggingFaceSearchService: HuggingFaceSearchService

    let onShowWelcome: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    @State private var pendingDeletionModel: RuntimeModelOption?
    @State private var isRecordingKeybind = false
    @State private var isRecordingFullAcceptKeybind = false
    @State private var isIndicatorIconImporterPresented = false
    @State private var didIndicatorIconImportFail = false

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
        .fileImporter(
            isPresented: $isIndicatorIconImporterPresented,
            allowedContentTypes: [.image]
        ) { result in
            handleIndicatorIconSelection(result)
        }
        .alert("Couldn't Use That Image", isPresented: $didIndicatorIconImportFail) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Cotabby couldn't read that file as an image. Try a PNG or JPEG.")
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
                .help("Master switch. Turn off to silence Cotabby in every app.")

            Toggle("Show Indicator", isOn: showIndicatorBinding)
                .help("Show a small icon next to the cursor when Cotabby is active in a field.")

            LabeledContent("Indicator Icon") {
                HStack(spacing: 8) {
                    FieldEdgeIconIndicatorView(customImage: suggestionSettings.customIndicatorImage)

                    Button("Choose Image…") {
                        isIndicatorIconImporterPresented = true
                    }

                    if suggestionSettings.customIndicatorImage != nil {
                        Button("Reset") {
                            suggestionSettings.clearCustomIndicatorImage()
                        }
                        .help("Go back to the default indicator icon.")
                    }
                }
            }
            .help("Custom image used in place of the default indicator. PNG or JPEG.")

            Toggle("Show Accept Hint", isOn: showAcceptanceHintBinding)
                .help("Show a small label near the ghost text reminding you which key accepts it.")

            Toggle("Allow Multi-line Suggestions", isOn: multiLineEnabledBinding)
                .help("Let suggestions span more than one line. Off keeps them to a single line.")

            Toggle("Accept Punctuation With Word", isOn: autoAcceptTrailingPunctuationBinding)
                .help("With this on, accepting a word also takes punctuation attached to it, like the \"?\" in \"you?\".")

            Toggle("Include Clipboard Context", isOn: clipboardContextEnabledBinding)
                .help("Include your latest clipboard contents in the prompt so completions can reference what you copied.")

            Toggle("Fast Mode", isOn: fastModeEnabledBinding)
                .help("Skip on-screen OCR context for faster, lower-overhead suggestions. Predictions still run.")

            LabeledContent("Ghost Text Color") {
                HStack(spacing: 8) {
                    ForEach(GhostTextColorPreset.all) { preset in
                        ghostColorSwatch(for: preset)
                    }
                }
            }
            .help("Color of the ghost text shown before you accept it.")

            LabeledContent("Ghost Text Opacity") {
                HStack(spacing: 10) {
                    TickMarkSlider(
                        value: ghostTextOpacityBinding,
                        range: SuggestionSettingsModel.minimumGhostTextOpacity
                            ... SuggestionSettingsModel.maximumGhostTextOpacity,
                        step: SuggestionSettingsModel.ghostTextOpacityStep
                    )
                    .frame(width: 180)

                    Text(ghostTextOpacityLabel)
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
            }
            .help("How visible the ghost text is. Lower values are subtler but harder to read.")

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

    /// Applies a picked image as the indicator icon, flagging an alert when the file can't be used.
    private func handleIndicatorIconSelection(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            if !suggestionSettings.setCustomIndicatorImage(from: url) {
                didIndicatorIconImportFail = true
            }

        case .failure:
            didIndicatorIconImportFail = true
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
            .help("Apple Intelligence runs on-device through macOS. Llama runs a local GGUF model you pick below.")

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
            .help("How long completions tend to be. Shorter is faster and less likely to overreach.")

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
                    .help("How Cotabby refers to you when it matters, like signing off an email.")
                }

                LanguageTagsEditor(suggestionSettings: suggestionSettings)

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
                        .help("Record a new key. Press any key to bind it; Escape to cancel.")
                    }

                    if suggestionSettings.acceptanceKeyCode != SuggestionSettingsModel.defaultAcceptanceKeyCode {
                        Button("Reset") {
                            suggestionSettings.setAcceptanceKey(
                                keyCode: SuggestionSettingsModel.defaultAcceptanceKeyCode,
                                label: SuggestionSettingsModel.defaultAcceptanceKeyLabel
                            )
                            isRecordingKeybind = false
                        }
                        .help("Restore the default key.")
                    }

                    if suggestionSettings.acceptanceKeyCode != SuggestionSettingsModel.disabledKeyCode {
                        Button("Clear") {
                            suggestionSettings.clearAcceptanceKey()
                            isRecordingKeybind = false
                        }
                        .help("Unbind this shortcut. No key will accept word-by-word.")
                    }
                }
            }
            .help("Key that accepts the next word of the suggestion.")

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
                        .help("Record a new key. Press any key to bind it; Escape to cancel.")
                    }

                    if suggestionSettings.fullAcceptanceKeyCode != SuggestionSettingsModel.defaultFullAcceptanceKeyCode {
                        Button("Reset") {
                            suggestionSettings.setFullAcceptanceKey(
                                keyCode: SuggestionSettingsModel.defaultFullAcceptanceKeyCode,
                                label: SuggestionSettingsModel.defaultFullAcceptanceKeyLabel
                            )
                            isRecordingFullAcceptKeybind = false
                        }
                        .help("Restore the default key.")
                    }

                    if suggestionSettings.fullAcceptanceKeyCode != SuggestionSettingsModel.disabledKeyCode {
                        Button("Clear") {
                            suggestionSettings.clearFullAcceptanceKey()
                            isRecordingFullAcceptKeybind = false
                        }
                        .help("Unbind this shortcut. No key will accept the whole suggestion at once.")
                    }
                }
            }
            .help("Key that accepts the whole suggestion at once.")
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
            .help("How long Cotabby waits after you stop typing before generating. Higher saves CPU; lower feels snappier.")

            // Focus poll interval is intentionally hidden from the UI. The default (50 ms)
            // is tuned for the best balance of responsiveness and CPU usage. Exposing it
            // invites misconfiguration without meaningful benefit. The backing setting and
            // UserDefaults plumbing remain so we can re-surface it later if needed.
        }
    }

    @ViewBuilder
    private var appsSection: some View {
        Section("Apps") {
            Text("Cotabby won't autocomplete in these apps. Add an app you can't disable from the "
                + "menu bar — like a launcher that closes the moment it loses focus.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(suggestionSettings.disabledAppRules) { rule in
                disabledAppRuleRow(rule)
            }

            Button("Add App…") {
                presentDisabledAppPicker()
            }
            .help("Pick an app to disable Cotabby in.")
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
                .help("Which GGUF file Cotabby loads. Larger models are smarter but slower and use more memory.")
            }

            DownloadableModelCatalogView(
                modelDownloadManager: modelDownloadManager,
                onRefreshModels: refreshModels
            )

            HuggingFaceModelBrowserView(
                searchService: huggingFaceSearchService,
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
                        let lmStudioAvailable = FileManager.default.fileExists(atPath: lmStudioURL.path)
                        let isUsingCustomPath = BundledRuntimeLocator.customModelDirectoryURL() != nil
                        Button("Use LM Studio") {
                            BundledRuntimeLocator.setCustomModelDirectory(lmStudioURL)
                            modelDownloadManager.refreshSearchDirectories()
                            refreshModels()
                        }
                        .disabled(!lmStudioAvailable)
                        .help(
                            lmStudioAvailable
                                ? "Point Cotabby at LM Studio's models folder (~/.lmstudio/models) so you don't keep two copies."
                                : "Install LM Studio with at least one model first. Cotabby couldn't find ~/.lmstudio/models."
                        )

                        Button("Reset Path") {
                            BundledRuntimeLocator.setCustomModelDirectory(nil)
                            modelDownloadManager.refreshSearchDirectories()
                            refreshModels()
                        }
                        .disabled(!isUsingCustomPath)
                        .help("Go back to Cotabby's default models folder.")

                        Button("Open Folder") {
                            modelDownloadManager.openModelsDirectory()
                        }

                        Button("Refresh") {
                            refreshModels()
                        }
                        .help("Re-scan the folder for newly added or removed model files.")
                    }
                }
            }
            .help("Where Cotabby looks for GGUF model files.")

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
                .help("Open System Settings to Privacy & Security so you can grant this permission.")
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

    private var fastModeEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isFastModeEnabled },
            set: { suggestionSettings.setFastModeEnabled($0) }
        )
    }

    private var showIndicatorBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.showIndicator },
            set: { suggestionSettings.setShowIndicator($0) }
        )
    }

    private var showAcceptanceHintBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.showAcceptanceHint },
            set: { suggestionSettings.setShowAcceptanceHint($0) }
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

    private var ghostTextOpacityBinding: Binding<Double> {
        Binding(
            get: { suggestionSettings.ghostTextOpacity },
            set: { suggestionSettings.setGhostTextOpacity($0) }
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

    /// Mirrors the overlay's automatic fallback (`GhostSuggestionView.ghostColor`) so the Automatic
    /// swatch previews the same gray the user will actually see.
    private var automaticGhostTextColor: Color {
        colorScheme == .dark
            ? Color(red: 0.65, green: 0.65, blue: 0.65)
            : Color(red: 0.45, green: 0.45, blue: 0.45)
    }

    private var ghostTextOpacityLabel: String {
        "\(Int((suggestionSettings.ghostTextOpacity * 100).rounded()))%"
    }

    /// A tappable color chip. `nil` hex selects the adaptive Automatic gray. The active preset gets a
    /// heavier ring so the current choice reads at a glance.
    @ViewBuilder
    private func ghostColorSwatch(for preset: GhostTextColorPreset) -> some View {
        let isSelected = GhostTextColorPreset.matching(
            hex: suggestionSettings.customSuggestionTextColorHex
        ) == preset

        Button {
            suggestionSettings.setCustomSuggestionTextColorHex(preset.hex)
        } label: {
            Circle()
                .fill(swatchFill(for: preset))
                .frame(width: 18, height: 18)
                .overlay(
                    Circle()
                        .strokeBorder(
                            Color.primary.opacity(isSelected ? 0.9 : 0.18),
                            lineWidth: isSelected ? 2 : 1
                        )
                )
        }
        .buttonStyle(.plain)
        .help(preset.name)
    }

    private func swatchFill(for preset: GhostTextColorPreset) -> Color {
        guard let hex = preset.hex,
              let color = SuggestionTextColorCodec.color(fromHex: hex)
        else {
            return automaticGhostTextColor
        }

        return color
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

    /// Lets the user disable Cotabby in an app they can't reach from the menu bar. The menu-bar
    /// "Enable in <app>" switch only targets the frontmost app, so a launcher like Raycast or
    /// Spotlight — which dismisses itself the instant the menu bar is clicked — can never be turned
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
