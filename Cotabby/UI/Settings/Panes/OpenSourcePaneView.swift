import SwiftUI

/// File overview:
/// "Open Source" sub-pane. Hosts everything the local llama runtime needs: selected model picker,
/// downloadable catalog, Hugging Face browser, models folder controls, and the installed-models
/// list with per-model delete. Lifted from the legacy `SettingsView.localModelControls` so
/// behavior is preserved verbatim; only the wrapping scaffold is new.
///
/// The engine picker itself lives on the parent overview pane; this pane offers a one-tap switch
/// affordance when the current engine is Apple Intelligence so users can land here and still flip
/// without bouncing back up the sidebar.
struct OpenSourcePaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var modelDownloadManager: ModelDownloadManager
    @ObservedObject var huggingFaceSearchService: HuggingFaceSearchService

    @State private var pendingDeletionModel: RuntimeModelOption?

    var body: some View {
        SettingsPaneScaffold(callout: callout) {
            Section("Open Source") {
                if !isSelectedEngine {
                    LabeledContent {
                        Button("Switch to Open Source") {
                            suggestionSettings.selectEngine(.llamaOpenSource)
                        }
                        .controlSize(.regular)
                    } label: {
                        Text("Currently using Apple Intelligence. Switch to use the local llama runtime.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                LabeledContent("Runtime") {
                    Text(runtimeModel.state.summary)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Models") {
                Text(localModelsDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if runtimeModel.availableModels.isEmpty {
                    Text("No local GGUF models found. Download one below or add your own model file.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Selected Model", selection: selectedModelBinding) {
                        ForEach(runtimeModel.availableModels) { model in
                            Text(model.displayName).tag(model.filename)
                        }
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

    private var isSelectedEngine: Bool {
        suggestionSettings.selectedEngine == .llamaOpenSource
    }

    /// Surface the runtime failure as a callout when the user is on this engine and the runtime
    /// crashed during preparation. Other failure modes (no models found) are conveyed by the
    /// inline empty-state text above.
    private var callout: SettingsPaneCallout? {
        guard isSelectedEngine,
              case .failed(let detail) = runtimeModel.state else {
            return nil
        }
        return SettingsPaneCallout(tone: .warning, message: detail)
    }

    private var localModelsDescription: String {
        switch suggestionSettings.selectedEngine {
        case .llamaOpenSource:
            return "Download a model or add your own below. Models are stored locally on your Mac."
        case .appleIntelligence:
            return "These models are used when Engine is set to Open Source."
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
