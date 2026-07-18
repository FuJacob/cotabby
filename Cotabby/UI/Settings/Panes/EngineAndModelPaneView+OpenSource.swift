import SwiftUI

/// In-process GGUF runtime, model discovery, downloads, and folder controls.
/// These members are internal because Swift extensions in separate files cannot share lexical `private` access;
/// the owning view itself remains module-internal.
extension EngineAndModelPaneView {
// MARK: - Open Source

    @ViewBuilder
    var openSourceSections: some View {
        Section("Runtime") {
            LabeledContent {
                Text(runtimeModel.state.summary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                SettingsRowLabel(
                    title: "Model Status",
                    description: "Whether the local model is loaded and ready to generate. " +
                        "Loading takes a few seconds the first time.",
                    systemImage: "info.circle"
                )
            }
            .settingsItem(.modelStatus)
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
                        description: suggestionSettings.isPowerBasedModelSwitchingEnabled
                            ? "Set automatically by power source. Use the On Battery / Plugged In " +
                                "pickers in the Power section, or turn off power-based switching."
                            : "Which downloaded model file generates suggestions. " +
                                "Larger models are slower but write better.",
                        systemImage: "shippingbox"
                    )
                }
                // Redundant while power-based switching owns the active model: the Power section's
                // per-source profile pickers are the source of truth, and any pick here would be
                // reverted on the next power evaluation.
                .disabled(suggestionSettings.isPowerBasedModelSwitchingEnabled)
                .settingsItem(.selectedModel)
            }

            DownloadableModelCatalogView(
                modelDownloadManager: modelDownloadManager,
                onRefreshModels: refreshModels
            )
            .settingsItem(.downloadModels)

            HuggingFaceModelBrowserView(
                searchService: huggingFaceSearchService,
                modelDownloadManager: modelDownloadManager,
                onRefreshModels: refreshModels
            )
            .settingsItem(.huggingFaceBrowser)
        }

        Section("Folder") {
            LabeledContent {
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
            } label: {
                SettingsRowLabel(
                    title: "Models Folder",
                    description: "Where downloaded model files are stored on this Mac.",
                    systemImage: "folder"
                )
            }
            .settingsItem(.modelsFolder)

            Toggle(isOn: $lmStudioSourceEnabled) {
                SettingsRowLabel(
                    title: "Also Use LM Studio Models",
                    description: lmStudioModelsURL == nil
                        ? "Install LM Studio to load models from its library here."
                        : "Add models from your LM Studio library (~/.lmstudio/models) to the picker " +
                            "above. Downloads still save to Cotabby's own folder.",
                    systemImage: "square.stack.3d.up"
                )
            }
            .disabled(lmStudioModelsURL == nil)
            .onChange(of: lmStudioSourceEnabled) { _, _ in
                modelDownloadManager.refreshSearchDirectories()
                refreshModels()
            }
            .settingsItem(.lmStudio)
        }

        if !runtimeModel.availableModels.isEmpty {
            Section("Installed") {
                ForEach(runtimeModel.availableModels) { model in
                    installedModelRow(model)
                }
            }
        }
    }
}
