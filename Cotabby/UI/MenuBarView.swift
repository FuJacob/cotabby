import SwiftUI

/// File overview:
/// Composes Cotabby's primary menu-bar control panel as a status-first surface
/// with inline quick controls for session-level preferences.
///
/// Design philosophy: the menu bar is the primary interaction surface for a menu bar app.
/// It shows status at a glance and exposes the controls users reach for mid-session
/// (engine, model, completion length). Rarely-changed settings (model management,
/// profile personalization, updates) live in the Settings window.
///
/// The focused-app context card was intentionally removed: opening the menu bar panel
/// steals focus from whatever app the user was typing in, so live focus state is always
/// stale by the time the panel renders.
struct MenuBarView: View {
    @ObservedObject var permissionManager: PermissionManager
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var modelDownloadManager: ModelDownloadManager
    @ObservedObject var focusModel: FocusTrackingModel
    let permissionGuidanceController: PermissionGuidanceController
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var foundationModelAvailabilityService: FoundationModelAvailabilityService
    let appUpdateManager: AppUpdateManager
    let onOpenSettings: () -> Void
    let onReportFeedback: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider().padding(.bottom, 12)
            controlsSection
            permissionsCard
            footerSection
        }
        .padding(16)
        .frame(width: 340)
        .modifier(MenuBarWindowBackgroundModifier())
        .background(
            MenuBarPresentationObserver {
                permissionManager.refresh()
                runtimeModel.refreshAvailableModels()
            }
        )
        .onAppear {
            permissionManager.refresh()
            runtimeModel.refreshAvailableModels()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        HStack(alignment: .center) {
            Text("Cotabby")
                .font(.headline)

            // Ko-fi tip jar lives next to the title because the menu bar surface is the most
            // frequented entry point. Using a Link lets SwiftUI hand the URL to NSWorkspace and
            // dismiss the popover; a Button would need its own handler plumbing for the same effect.
            if let kofiURL = URL(string: "https://ko-fi.com/cotabby") {
                Link("Support Us", destination: kofiURL)
                    .buttonStyle(.borderless)
                    .font(.subheadline)
            }

            Spacer(minLength: 0)

            Button("Report Bug", action: onReportFeedback)
                .buttonStyle(.borderless)
                .font(.subheadline)
        }
        .padding(.bottom, 12)
    }

    // MARK: - Quick controls

    /// Session-level preferences that users reach for mid-work: engine choice,
    /// model selection (when using local llama), and completion length.
    @ViewBuilder
    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Fast Mode", isOn: fastModeEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.small)

            Divider()

            // Activation lives in its own band: the global switch plus the per-app override for
            // whatever app currently has focus.
            Group {
                Toggle("Enable Globally", isOn: globallyEnabledBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                if let application = focusModel.latestExternalApplication,
                   !TerminalAppDetector.isTerminal(bundleIdentifier: application.bundleIdentifier) {
                    Toggle("Enable in \(application.applicationName)", isOn: appEnabledBinding(for: application))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            Divider()

            // Context-shaping toggles that change what the model is fed.
            Group {
                Toggle("Include Clipboard Context", isOn: clipboardContextEnabledBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Toggle("Allow Multi-line Suggestions", isOn: multiLineEnabledBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Divider()

            // Generation setup: which engine/model produces completions and how long they run.
            // Wrapped in a Group so the four rows plus the toggles and dividers above stay under
            // SwiftUI's 10-child ViewBuilder limit for the enclosing VStack.
            Group {
                MenuBarPickerRow(title: "Engine") {
                    Picker("Engine", selection: selectedEngineBinding) {
                        ForEach(SuggestionEngineKind.allCases) { engine in
                            Text(engine.displayLabel)
                                .tag(engine)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                if suggestionSettings.selectedEngine == .appleIntelligence,
                   !foundationModelAvailabilityService.isAvailable {
                    Text(foundationModelAvailabilityService.userVisibleMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if suggestionSettings.selectedEngine.supportsLocalModelManagement {
                    modelRow
                }

                MenuBarPickerRow(title: "Length") {
                    Picker("Length", selection: selectedWordCountPresetBinding) {
                        ForEach(SuggestionWordCountPreset.allCases) { preset in
                            Text(preset.displayLabel)
                                .tag(preset)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                MenuBarPickerRow(title: "Display") {
                    Picker("Display", selection: mirrorPreferenceBinding) {
                        ForEach(MirrorPreference.allCases) { preference in
                            Text(preference.displayLabel)
                                .tag(preference)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
        }
        .padding(.bottom, 12)
    }

    /// Model selector with folder + refresh shortcuts — only visible when local llama engine is active.
    /// The picker is constrained to fill remaining row width so long filenames truncate inside the
    /// NSPopUpButton label instead of pushing the trailing icons off-row. Per-item `.lineLimit` /
    /// `.truncationMode` modifiers are unreliable here because AppKit's native popup ignores them
    /// for the selected-value label.
    @ViewBuilder
    private var modelRow: some View {
        MenuBarPickerRow(title: "Model") {
            HStack(spacing: 6) {
                if runtimeModel.availableModels.isEmpty {
                    Text("No models found")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    Picker("Model", selection: selectedModelBinding) {
                        ForEach(runtimeModel.availableModels) { model in
                            Text(model.displayName)
                                .tag(model.filename)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                    .disabled(runtimePickerDisabled)
                }

                Button {
                    modelDownloadManager.openModelsDirectory()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                Button {
                    modelDownloadManager.refreshModelStates()
                    runtimeModel.refreshAvailableModels()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Permissions (conditional)

    /// Only appears when at least one permission is missing. Once all are granted, this
    /// section vanishes — no wasted space on resolved state.
    @ViewBuilder
    private var permissionsCard: some View {
        if !allPermissionsGranted {
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions")
                    .font(.subheadline.weight(.medium))
                    .padding(.bottom, 2)

                ForEach(CotabbyPermissionKind.allCases.filter(\.isRequiredForAutocomplete)) { permission in
                    PermissionRow(
                        title: permission.title,
                        granted: permissionManager.isGranted(permission),
                        action: { sourceFrameInScreen in
                            permissionGuidanceController.requestAccess(
                                for: permission,
                                sourceFrameInScreen: sourceFrameInScreen
                            )
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 12)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerSection: some View {
        Divider()
            .padding(.bottom, 10)

        HStack {
            Button("Settings", action: onOpenSettings)
                .buttonStyle(.borderless)

            Button("Check for Updates") {
                appUpdateManager.checkForUpdates()
            }
            .buttonStyle(.borderless)

            Spacer(minLength: 0)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q")
        }
        .font(.subheadline)
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

    private func appEnabledBinding(for application: FocusedApplicationIdentity) -> Binding<Bool> {
        Binding(
            get: {
                !suggestionSettings.isApplicationDisabled(
                    bundleIdentifier: application.bundleIdentifier
                )
            },
            set: { enabled in
                suggestionSettings.setApplicationDisabled(
                    bundleIdentifier: application.bundleIdentifier,
                    displayName: application.applicationName,
                    disabled: !enabled
                )
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

    private var multiLineEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isMultiLineEnabled },
            set: { suggestionSettings.setMultiLineEnabled($0) }
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

    private var mirrorPreferenceBinding: Binding<MirrorPreference> {
        Binding(
            get: { suggestionSettings.mirrorPreference },
            set: { suggestionSettings.setMirrorPreference($0) }
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

    private var runtimePickerDisabled: Bool {
        switch runtimeModel.state {
        case .starting, .loading:
            return true
        case .idle, .ready, .failed:
            return false
        }
    }

    // MARK: - Derived state

    private var allPermissionsGranted: Bool {
        permissionManager.requiredPermissionsGranted
    }

}

/// Applies the menu panel's fill at the native window-container level when the OS supports it.
///
/// `MenuBarView` owns the menu contents, but SwiftUI owns the actual `NSWindow` created by
/// `MenuBarExtra`. Keeping this as a dedicated modifier gives the UI a narrow boundary for one
/// platform-specific presentation rule without mixing availability checks into the main view body.
private struct MenuBarWindowBackgroundModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            // MenuBarExtra's `.window` style already gives us native rounded window chrome.
            // On newer macOS builds, leaving the root fill implicit can make SwiftUI draw a
            // second, inset window-colored rectangle inside that chrome. A container background
            // belongs to the hosting window instead of this view's local bounds, so the fill
            // reaches the native rounded frame and avoids the double-border look.
            content.containerBackground(.windowBackground, for: .window)
        } else {
            content
        }
    }
}
