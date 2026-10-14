import SwiftUI

/// MLX sections of the unified engine pane: the mlx-lm install, the model list (curated, cached
/// and custom), and the prompt-cache cap. The pane presents state and forwards actions. Installing,
/// running and downloading live in `MLXToolchainProvisioner`, `MLXServerManager` and
/// `MLXModelDownloader`, which `CotabbyAppEnvironment` owns.
extension EngineAndModelPaneView {
    @ViewBuilder
    var mlxSections: some View {
        mlxRuntimeSection
        mlxModelSection
        mlxAdvancedSection
    }

    // MARK: - Runtime

    private var mlxRuntimeSection: some View {
        Section("MLX") {
            LabeledContent {
                mlxRuntimeControls
            } label: {
                SettingsRowLabel(title: "MLX", description: mlxRuntimeDescription, systemImage: "bolt.fill")
            }
            .settingsItem(.mlxRuntime)

            if let tail = mlxVisibleLogTail, !tail.isEmpty {
                Text(tail.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(20)
            }
        }
        .alert("Remove MLX?", isPresented: $showsMLXRemoveConfirmation) {
            Button("Remove", role: .destructive) {
                Task {
                    mlxIsBusy = true
                    defer { mlxIsBusy = false }
                    await mlxToolchainProvisioner.remove()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes Cotabby's copy of mlx-lm and its Python. Downloaded models stay in the Hugging Face cache.")
        }
    }

    private var mlxRuntimeDescription: String {
        switch mlxToolchainProvisioner.state {
        case .checking:
            return "Checking for MLX…"
        case .notInstalled:
            return "Cotabby installs Apple's mlx-lm and runs it on this Mac (about 250 MB, plus a model)."
        case .tooOld(let version, let path):
            return "Found mlx-lm \(version) at \(path). Cotabby needs \(MLXToolchainRules.minimumVersion) " +
                "or newer; Install adds Cotabby's own copy."
        case .installing(let phase):
            return phase.label
        case .ready(let toolchain):
            let owner = toolchain.isCotabbyInstall ? "Cotabby's" : "Your"
            return "\(owner) mlx-lm \(toolchain.version). \(mlxServerManager.state.summary)"
        case .failed(let reason, _):
            return reason
        }
    }

    @ViewBuilder
    private var mlxRuntimeControls: some View {
        switch mlxToolchainProvisioner.state {
        case .checking:
            ProgressView().controlSize(.small)
        case .notInstalled, .tooOld, .failed:
            Button("Install MLX") { mlxToolchainProvisioner.install() }
                .buttonStyle(.borderedProminent)
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Button("Cancel") { mlxToolchainProvisioner.cancelInstall() }
            }
        case .ready(let toolchain):
            HStack(spacing: 8) {
                if case .failed = mlxServerManager.state {
                    Button("Retry") {
                        Task {
                            await mlxToolchainProvisioner.rescan(models: mlxModelDownloader)
                            await mlxServerManager.retry()
                        }
                    }
                }
                if toolchain.isCotabbyInstall {
                    Button("Remove MLX…", role: .destructive) { showsMLXRemoveConfirmation = true }
                        .disabled(mlxIsBusy)
                }
            }
        }
    }

    /// The server's failure tail, else the install's.
    private var mlxVisibleLogTail: [String]? {
        if case .failed(_, let tail) = mlxServerManager.state { return tail }
        if case .failed(_, let tail) = mlxToolchainProvisioner.state { return tail }
        return nil
    }

    // MARK: - Models

    private var mlxModelSection: some View {
        Section("Model") {
            let options = MLXModelCatalog.options(cached: mlxModelDownloader.cachedModels ?? [])
            ForEach(options) { option in
                // `settingsItem` sets the row's `.id`; only one row may carry the search anchor.
                if option.id == options.first?.id {
                    mlxModelRow(option).settingsItem(.mlxModel)
                } else {
                    mlxModelRow(option)
                }
            }
            mlxCustomRepoRow(downloadWithoutRow: MLXModelCatalog.downloadWithoutRow(
                mlxModelDownloader.download, options: options))
        }
        .alert(
            "Delete MLX Model?",
            isPresented: Binding(
                get: { pendingMLXDeletion != nil },
                set: { if !$0 { pendingMLXDeletion = nil } }
            ),
            presenting: pendingMLXDeletion
        ) { option in
            Button("Delete", role: .destructive) { deleteMLXModel(option) }
            Button("Cancel", role: .cancel) {}
        } message: { option in
            Text("Remove \(option.repoID.value) from the shared Hugging Face cache? Other apps that use this cache lose it too.")
        }
    }

    private func mlxModelRow(_ option: MLXModelOption) -> some View {
        let download = mlxModelDownloader.download?.repoID == option.repoID ? mlxModelDownloader.download : nil
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(option.displayName)
                    if option.isRecommended {
                        Text("Recommended").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(([ByteCountFormatter.string(fromByteCount: option.sizeBytes, countStyle: .file)] + [option.note].compactMap { $0 })
                    .joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let download { mlxDownloadStatus(download) }
            }
            Spacer(minLength: 8)
            mlxModelActions(option, isDownloading: download?.isActive == true)
        }
    }

    /// Progress while a download runs, and its error once it failed.
    @ViewBuilder
    private func mlxDownloadStatus(_ download: MLXDownloadState) -> some View {
        if download.isActive {
            if let fraction = download.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
        if let failure = download.failure {
            Text(failure).font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func mlxModelActions(_ option: MLXModelOption, isDownloading: Bool) -> some View {
        if option.isDownloaded {
            if suggestionSettings.mlxModelID == option.repoID.value {
                Label("In Use", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Use") { suggestionSettings.setMLXModelID(option.repoID.value) }
                    .disabled(mlxIsBusy)
            }
            Button {
                pendingMLXDeletion = option
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(mlxIsBusy)
            .help("Delete from the Hugging Face cache")
        } else if isDownloading {
            Button("Cancel") { mlxModelDownloader.cancelDownload() }
        } else {
            Button("Download") { startMLXDownload(option.repoID) }
                .disabled(!canStartMLXDownload)
                .help(mlxToolchainProvisioner.state.toolchain == nil ? "Install MLX first." : "")
        }
    }

    /// `downloadWithoutRow` is a custom model's download, which has no catalog row until it is
    /// cached; its progress, Cancel and failure are shown here instead.
    private func mlxCustomRepoRow(downloadWithoutRow: MLXDownloadState?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsRowLabel(
                title: "Other MLX Model",
                description: "A Hugging Face model id or link, for example mlx-community/Qwen3-4B-4bit. " +
                    "Base models complete text better than chat models.",
                systemImage: "plus.circle"
            )
            HStack(spacing: 8) {
                TextField("", text: $mlxCustomRepoDraft, prompt: Text("owner/model"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(checkMLXCustomRepo)
                    .onChange(of: mlxCustomRepoDraft) { _, _ in mlxCustomValidation = nil }
                Button("Check", action: checkMLXCustomRepo)
                    .disabled(mlxCustomRepoDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || mlxIsCheckingCustomRepo || mlxIsBusy)
                if case .valid(let repoID, _, _) = mlxCustomValidation {
                    Button("Download") { startMLXDownload(repoID) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canStartMLXDownload)
                }
            }
            if case .valid(let repoID, let bytes, let isInstruct) = mlxCustomValidation {
                Text("\(repoID.value) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isInstruct {
                    Text(MLXModelCatalog.instructNote).font(.caption).foregroundStyle(.secondary)
                }
            } else if let message = mlxCustomValidation?.message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            if let download = downloadWithoutRow {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(download.repoID.value).font(.caption)
                        mlxDownloadStatus(download)
                    }
                    Spacer(minLength: 8)
                    if download.isActive {
                        Button("Cancel") { mlxModelDownloader.cancelDownload() }
                    }
                }
            }
        }
        .settingsItem(.mlxCustomModel)
    }

    // MARK: - Advanced

    private var mlxAdvancedSection: some View {
        Section {
            DisclosureGroup("Advanced") {
                Picker(selection: Binding(
                    get: { suggestionSettings.mlxPromptCacheBytes },
                    set: { suggestionSettings.setMLXPromptCacheBytes($0) }
                )) {
                    ForEach(promptCacheOptions, id: \.self) { bytes in
                        Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)).tag(bytes)
                    }
                } label: {
                    SettingsRowLabel(
                        title: "Prompt Cache Memory",
                        description: "The most memory MLX keeps for reusing recent prompts. More can speed up " +
                            "suggestions in long documents; changing it restarts MLX.",
                        systemImage: "memorychip"
                    )
                }
                .pickerStyle(.menu)
                .settingsItem(.mlxPromptCache)
            }
        }
    }

    /// The four presets, plus the stored value when it is off-preset (the store clamps to
    /// 256 MiB...8 GiB), so the menu always has a tag for the current selection.
    private var promptCacheOptions: [Int] {
        let presets = [512 << 20, 1 << 30, 2 << 30, 4 << 30]
        let current = suggestionSettings.mlxPromptCacheBytes
        return presets.contains(current) ? presets : (presets + [current]).sorted()
    }

    // MARK: - Actions

    private var canStartMLXDownload: Bool {
        mlxToolchainProvisioner.state.toolchain != nil && mlxModelDownloader.download?.isActive != true
            && !mlxIsBusy
    }

    func startMLXDownload(_ repoID: MLXRepoID) {
        guard let toolchain = mlxToolchainProvisioner.state.toolchain else { return }
        mlxModelDownloader.startDownload(repoID, toolchain: toolchain)
    }

    func checkMLXCustomRepo() {
        let draft = mlxCustomRepoDraft
        mlxIsCheckingCustomRepo = true
        Task {
            let result = await mlxModelDownloader.validateCustomRepo(draft, toolchain: mlxToolchainProvisioner.state.toolchain)
            mlxIsCheckingCustomRepo = false
            // The field may have changed while the check ran; a stale answer would mislabel it.
            guard draft == mlxCustomRepoDraft else { return }
            mlxCustomValidation = result
        }
    }

    /// Deletes the model from the cache and does not stop the server itself. The pipeline in
    /// `CotabbyAppEnvironment` stops it when the cache rescan publishes without the model, which
    /// keeps stops on the serialized, de-duplicated desire path. A running server keeps its
    /// memory-mapped weights valid after the files are unlinked, so deleting first is safe.
    func deleteMLXModel(_ option: MLXModelOption) {
        Task {
            mlxIsBusy = true
            defer { mlxIsBusy = false }
            await mlxModelDownloader.delete(option.repoID, toolchain: mlxToolchainProvisioner.state.toolchain)
        }
    }
}
