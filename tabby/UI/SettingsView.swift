import SwiftUI

/// File overview:
/// Renders Tabby's settings window using the app's existing long-lived services.
/// This view intentionally does not own persistence, runtime bootstrap, or updater lifecycle.
/// It is a read/write surface over those services, while `SettingsCoordinator` owns the window.
///
/// Uses `Form` with `.formStyle(.grouped)` for native macOS settings appearance — this gives us
/// automatic label alignment, section grouping with rounded containers, and proper row spacing
/// without any custom layout scaffolding.
struct SettingsView: View {
    let appUpdateManager: AppUpdateManager

    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var foundationModelAvailabilityService: FoundationModelAvailabilityService
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var modelDownloadManager: ModelDownloadManager
    @State private var pendingDeletionModel: RuntimeModelOption?

    var body: some View {
        Form {
            updatesSection
            autocompleteSection

            if suggestionSettings.selectedEngine.supportsLocalModelManagement {
                modelsSection
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 420)
        .onAppear {
            refreshAppleIntelligenceAvailabilityIfNeeded()
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
    private var autocompleteSection: some View {
        Section("Autocomplete") {
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

            if suggestionSettings.selectedEngine.supportsPromptModeSelection {
                Picker("Prompt", selection: selectedLocalPromptModeBinding) {
                    ForEach(suggestionSettings.availablePromptModes) { mode in
                        Text(mode.displayLabel)
                            .tag(mode)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var modelsSection: some View {
        Section("Models") {
            LabeledContent("Location") {
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

            if runtimeModel.availableModels.isEmpty {
                Text("No local GGUF models found.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(runtimeModel.availableModels) { model in
                    installedModelRow(model)
                }
            }
        }
    }

    @ViewBuilder
    private func installedModelRow(_ model: RuntimeModelOption) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)

                if model.displayName != model.filename {
                    Text(model.filename)
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

    private var selectedLocalPromptModeBinding: Binding<SuggestionPromptMode> {
        Binding(
            get: { suggestionSettings.selectedLocalPromptMode },
            set: { mode in
                suggestionSettings.selectLocalPromptMode(mode)
            }
        )
    }

    /// The app bundle is the canonical source for human-facing version text.
    private var appVersionText: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion, buildNumber) {
        case let (shortVersion?, buildNumber?) where shortVersion != buildNumber:
            return "\(shortVersion) (\(buildNumber))"
        case let (shortVersion?, _):
            return shortVersion
        case let (_, buildNumber?):
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
