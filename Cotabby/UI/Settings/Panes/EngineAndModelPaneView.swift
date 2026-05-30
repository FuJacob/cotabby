import SwiftUI

/// File overview:
/// Single pane that hosts everything engine-and-model related. The dropdown at the top is both
/// the active-engine selector and the in-pane switcher: picking Apple Intelligence shows the
/// availability section; picking Open Source shows the local-runtime stack (model picker,
/// downloads, Hugging Face browser, folder controls, installed models). One pane keeps the
/// settings sidebar flat and gives users a single place to manage everything model-related.
struct EngineAndModelPaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var foundationModelAvailabilityService: FoundationModelAvailabilityService
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var modelDownloadManager: ModelDownloadManager
    @ObservedObject var huggingFaceSearchService: HuggingFaceSearchService

    @State private var pendingDeletionModel: RuntimeModelOption?

    var body: some View {
        SettingsPaneScaffold(callout: callout) {
            Section("Engine") {
                Picker(selection: selectedEngineBinding) {
                    ForEach(SuggestionEngineKind.allCases) { engine in
                        Text(engine.displayLabel).tag(engine)
                    }
                } label: {
                    SettingsRowLabel(
                        title: "Engine",
                        description: "Apple Intelligence runs on-device using macOS's built-in model " +
                            "(newer Apple Silicon Macs only). Open Source runs a model file you download " +
                            "and pick below."
                    )
                }
                .pickerStyle(.menu)
            }

            switch suggestionSettings.selectedEngine {
            case .appleIntelligence:
                appleIntelligenceSections
            case .llamaOpenSource:
                openSourceSections
            }
        }
        .onAppear { foundationModelAvailabilityService.refresh() }
        .alert(
            "Delete Model?",
            isPresented: pendingDeletionAlertBinding,
            presenting: pendingDeletionModel
        ) { model in
            Button("Delete") { deleteModel(model) }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text("Remove \(model.displayName) from Cotabby's local models folder?")
        }
    }

    // MARK: - Apple Intelligence

    @ViewBuilder
    private var appleIntelligenceSections: some View {
        Section("Apple Intelligence") {
            LabeledContent("Availability") {
                Text(foundationModelAvailabilityService.userVisibleMessage)
                    .foregroundStyle(foundationModelAvailabilityService.isAvailable ? .green : .orange)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Open Source

    @ViewBuilder
    private var openSourceSections: some View {
        Section("Runtime") {
            LabeledContent {
                Text(runtimeModel.state.summary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                SettingsRowLabel(
                    title: "Status",
                    description: "Whether the local model is loaded and ready to generate. " +
                        "Loading takes a few seconds the first time."
                )
            }
        }

        Section("Models") {
            Text("Download a model or add your own below. Models are stored locally on your Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if runtimeModel.availableModels.isEmpty {
                Text("No local GGUF models found. Download one below or add your own model file.")
                    .foregroundStyle(.secondary)
            } else {
                Picker(selection: selectedModelBinding) {
                    ForEach(runtimeModel.availableModels) { model in
                        Text(model.displayName).tag(model.filename)
                    }
                } label: {
                    SettingsRowLabel(
                        title: "Selected Model",
                        description: "Which downloaded model file generates suggestions. " +
                            "Larger models are slower but write better."
                    )
                }
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
        }

        Section("Folder") {
            LabeledContent("Path") {
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
        }

        if !runtimeModel.availableModels.isEmpty {
            Section("Installed") {
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
            }
        }
    }

    // MARK: - Callout

    /// Surface the engine's failure mode at the top of the pane so it sits next to the controls
    /// that fix it. Only the selected engine surfaces a warning; the inactive engine's status is
    /// informational and doesn't warrant alarming the user.
    private var callout: SettingsPaneCallout? {
        switch suggestionSettings.selectedEngine {
        case .appleIntelligence:
            guard !foundationModelAvailabilityService.isAvailable else { return nil }
            return SettingsPaneCallout(
                tone: .warning,
                message: foundationModelAvailabilityService.userVisibleMessage
            )
        case .llamaOpenSource:
            guard case .failed(let detail) = runtimeModel.state else { return nil }
            return SettingsPaneCallout(tone: .warning, message: detail)
        }
    }

    // MARK: - Bindings & actions

    private var selectedEngineBinding: Binding<SuggestionEngineKind> {
        Binding(
            get: { suggestionSettings.selectedEngine },
            set: { suggestionSettings.selectEngine($0) }
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
                Task { await runtimeModel.selectModel(filename) }
            }
        )
    }

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
