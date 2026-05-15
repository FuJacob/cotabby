import SwiftUI

/// File overview:
/// Composes Tabby's primary menu-bar control panel as a status-first surface
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
    @ObservedObject var suggestionCoordinator: SuggestionCoordinator
    let onOpenSettings: () -> Void

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
        .background(
            MenuBarPresentationObserver {
                permissionManager.refresh()
            }
        )
        .onAppear {
            // The menu is a status surface, so re-read system permissions whenever it opens.
            // The background poll eventually catches changes too, but this avoids showing stale
            // "Grant" rows after the user just updated System Settings.
            permissionManager.refresh()
            refreshAppleIntelligenceAvailabilityIfNeeded()
        }
        .onChange(of: suggestionSettings.selectedEngine) { _, _ in
            refreshAppleIntelligenceAvailabilityIfNeeded()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        HStack(alignment: .center) {
            Text("Tabby")
                .font(.headline)

            Spacer(minLength: 0)

            Text("\(suggestionCoordinator.totalTabAcceptedWordCount) words accepted")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 12)
    }

    // MARK: - Quick controls

    /// Session-level preferences that users reach for mid-work: engine choice,
    /// model selection (when using local llama), and completion length.
    @ViewBuilder
    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enable Globally", isOn: globallyEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.small)

            if let application = focusModel.latestExternalApplication {
                Toggle("Enable in \(application.applicationName)", isOn: appEnabledBinding(for: application))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            MenuBarPickerRow(title: "Indicator") {
                Picker("Indicator", selection: selectedIndicatorModeBinding) {
                    ForEach(ActivationIndicatorMode.allCases) { mode in
                        Text(mode.compactLabel)
                            .tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

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
        }
        .padding(.bottom, 12)
    }

    /// Model selector with folder shortcut — only visible when local llama engine is active.
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
                    .disabled(runtimePickerDisabled)
                }

                Button {
                    modelDownloadManager.openModelsDirectory()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Open Models Folder")
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

                ForEach(TabbyPermissionKind.allCases.filter(\.isRequiredForAutocomplete)) { permission in
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
            Button("Settings…", action: onOpenSettings)
                .buttonStyle(.borderless)

            Spacer(minLength: 0)

            Button("Quit Tabby") {
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

    private var selectedIndicatorModeBinding: Binding<ActivationIndicatorMode> {
        Binding(
            get: { suggestionSettings.selectedIndicatorMode },
            set: { suggestionSettings.selectIndicatorMode($0) }
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

    private func refreshAppleIntelligenceAvailabilityIfNeeded() {
        guard suggestionSettings.selectedEngine == .appleIntelligence else {
            return
        }

        foundationModelAvailabilityService.refresh()
    }
}
