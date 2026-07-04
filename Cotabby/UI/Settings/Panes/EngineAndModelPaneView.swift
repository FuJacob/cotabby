import SwiftUI

/// File overview:
/// Single pane that hosts everything engine-and-model related. The dropdown at the top is both
/// the active-engine selector and the in-pane switcher: picking Apple Intelligence shows the
/// availability section; picking Open Source shows the local-runtime stack (model picker,
/// downloads, Hugging Face browser, folder controls, installed models). One pane keeps the
/// settings sidebar flat and gives users a single place to manage everything model-related.
struct EngineAndModelPaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var openAICompatibleConnectionModel: OpenAICompatibleConnectionModel
    @ObservedObject var foundationModelAvailabilityService: FoundationModelAvailabilityService
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var modelDownloadManager: ModelDownloadManager
    @ObservedObject var huggingFaceSearchService: HuggingFaceSearchService

    @State private var pendingDeletionModel: RuntimeModelOption?
    @State private var endpointAPIKeyDraft = ""
    @State private var endpointCredentialError: String?
    /// The LM Studio models directory if it exists, probed once in `onAppear` so the filesystem
    /// `fileExists` check never runs on the SwiftUI render path. Nil disables the LM Studio toggle.
    @State private var lmStudioModelsURL: URL?
    /// Whether to also scan the user's LM Studio library. Persisted via the same key the locator
    /// reads, so the toggle and the model scan stay in sync. LM Studio models are an additive,
    /// read-only source; Cotabby's own folder is always scanned and is always the download target.
    @AppStorage(BundledRuntimeLocator.lmStudioSourceEnabledKey) private var lmStudioSourceEnabled = false

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
                            "(newer Apple Silicon Macs only). Open Source runs a downloaded model file. " +
                            "Local Endpoint connects to an OpenAI-compatible server you manage.",
                        systemImage: "cpu"
                    )
                }
                .pickerStyle(.menu)
                .settingsItem(.engine)
            }

            powerSection

            switch suggestionSettings.selectedEngine {
            case .appleIntelligence:
                appleIntelligenceSections
            case .llamaOpenSource:
                openSourceSections
            case .openAICompatible:
                openAICompatibleSections
            }
        }
        .onAppear {
            foundationModelAvailabilityService.refresh()

            suggestionSettings.initializePowerProfiles(
                currentEngine: suggestionSettings.selectedEngine,
                currentModelFilename: runtimeModel.selectedModelFilename,
                currentEndpointModelName: suggestionSettings.openAICompatibleModelName
            )

            lmStudioModelsURL = BundledRuntimeLocator.lmStudioModelsDirectoryIfAvailable()

            // If LM Studio was uninstalled while the source was enabled, clear the persisted flag so
            // the toggle does not sit checked-but-disabled with no way to turn it off (and so the
            // source does not silently reactivate if LM Studio is later reinstalled).
            if lmStudioModelsURL == nil, lmStudioSourceEnabled {
                lmStudioSourceEnabled = false
            }

            loadEndpointAPIKey()
            if suggestionSettings.selectedEngine == .openAICompatible,
               openAICompatibleConnectionModel.state == .idle {
                refreshEndpointModels()
            }
        }
        .onChange(of: suggestionSettings.selectedEngine) { _, engine in
            if engine == .openAICompatible, openAICompatibleConnectionModel.state == .idle {
                refreshEndpointModels()
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

    // MARK: - Power

    /// Engine-level section (shown for any engine) that lets the user pick a different profile,
    /// Apple Intelligence or a specific local model, for battery vs. plugged-in power. Apple
    /// Intelligence is offered only when it is actually available on this Mac.
    @ViewBuilder
    private var powerSection: some View {
        Section("Power") {
            Toggle(
                isOn: Binding(
                    get: { suggestionSettings.isPowerBasedModelSwitchingEnabled },
                    set: { suggestionSettings.setPowerBasedModelSwitchingEnabled($0) }
                )
            ) {
                SettingsRowLabel(
                    title: "Switch Based on Power Source",
                    description: "Use a different engine or model on battery vs. while plugged in. " +
                        "For example, Apple Intelligence on battery to save power and a larger local " +
                        "model while charging.",
                    systemImage: "battery.100.bolt"
                )
            }
            .settingsItem(.powerBasedModelSwitching)

            if suggestionSettings.isPowerBasedModelSwitchingEnabled {
                powerProfilePicker(
                    title: "On Battery",
                    systemImage: "battery.25",
                    selection: batteryProfileBinding
                )
                .settingsItem(.batteryModel)

                powerProfilePicker(
                    title: "Plugged In",
                    systemImage: "powerplug",
                    selection: pluggedInProfileBinding
                )
                .settingsItem(.pluggedInModel)
            }
        }
    }

    /// One per-power-source profile picker. Lists Apple Intelligence (only when available) plus every
    /// installed local model, tagged by `PowerProfile` so a single selection carries engine + model.
    @ViewBuilder
    private func powerProfilePicker(
        title: String,
        systemImage: String,
        selection: Binding<PowerProfile>
    ) -> some View {
        Picker(selection: selection) {
            if foundationModelAvailabilityService.isAvailable {
                Text("Apple Intelligence").tag(PowerProfile.appleIntelligence)
            }

            ForEach(runtimeModel.availableModels) { model in
                Text(model.displayName).tag(PowerProfile.llama(filename: model.filename))
            }

            ForEach(endpointPowerModels, id: \.self) { modelName in
                Text("Endpoint · \(modelName)").tag(PowerProfile.openAICompatible(modelName: modelName))
            }
        } label: {
            SettingsRowLabel(
                title: title,
                description: "Engine and model to use while on this power source.",
                systemImage: systemImage
            )
        }
        .pickerStyle(.menu)
    }

    private var batteryProfileBinding: Binding<PowerProfile> {
        Binding(
            get: { powerProfileForDisplay(suggestionSettings.batteryProfile) },
            set: { suggestionSettings.setBatteryProfile($0) }
        )
    }

    private var pluggedInProfileBinding: Binding<PowerProfile> {
        Binding(
            get: { powerProfileForDisplay(suggestionSettings.pluggedInProfile) },
            set: { suggestionSettings.setPluggedInProfile($0) }
        )
    }

    /// Falls a not-yet-chosen local profile back to the currently selected model so the picker shows
    /// a concrete row instead of an empty selection, mirroring the primary model picker's fallback.
    private func powerProfileForDisplay(_ profile: PowerProfile) -> PowerProfile {
        if case .llama(let filename) = profile, filename.isEmpty {
            return .llama(filename: runtimeModel.selectedModelFilename ?? "")
        }
        if case .openAICompatible(let modelName) = profile, modelName.isEmpty {
            return .openAICompatible(modelName: suggestionSettings.openAICompatibleModelName)
        }

        return profile
    }

    private var endpointPowerModels: [String] {
        var names = openAICompatibleConnectionModel.models.map(\.id)
        let configured = suggestionSettings.openAICompatibleModelName
        if !configured.isEmpty, !names.contains(configured) {
            names.append(configured)
        }
        return names
    }

    // MARK: - Apple Intelligence

    @ViewBuilder
    private var appleIntelligenceSections: some View {
        Section("Apple Intelligence") {
            LabeledContent {
                Text(foundationModelAvailabilityService.userVisibleMessage)
                    .foregroundStyle(foundationModelAvailabilityService.isAvailable ? .green : .orange)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                SettingsRowLabel(
                    title: "Availability",
                    description: "Whether this Mac can run Apple Intelligence. Requires a supported " +
                        "Apple Silicon Mac with Apple Intelligence turned on in System Settings.",
                    systemImage: "apple.logo"
                )
            }
            .settingsItem(.appleIntelligenceAvailability)
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

    // MARK: - OpenAI-compatible endpoint

    /// Endpoint controls stay inside the unified engine pane. The connection model owns network
    /// state, the settings model owns durable non-secret values, and the API key draft only lives
    /// for this view's lifetime before an explicit Connect saves it to Keychain.
    @ViewBuilder
    private var openAICompatibleSections: some View {
        Section("Connection") {
            LabeledContent {
                HStack(spacing: 8) {
                    TextField(
                        OpenAICompatibleEndpointConfiguration.defaultBaseURLString,
                        text: endpointBaseURLBinding
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .onSubmit(refreshEndpointModels)

                    Button(
                        openAICompatibleConnectionModel.state == .ready(modelCount: openAICompatibleConnectionModel.models.count)
                            ? "Refresh" : "Connect",
                        action: refreshEndpointModels
                    )
                    .disabled(openAICompatibleConnectionModel.state == .connecting)
                }
            } label: {
                SettingsRowLabel(
                    title: "Base URL",
                    description: "The OpenAI-compatible /v1 base URL. Ollama uses " +
                        "http://127.0.0.1:11434/v1 by default.",
                    systemImage: "network"
                )
            }
            .settingsItem(.endpointBaseURL)

            Picker(selection: endpointAPIModeBinding) {
                ForEach(OpenAICompatibleAPIMode.allCases) { mode in
                    Text(mode.displayLabel).tag(mode)
                }
            } label: {
                SettingsRowLabel(
                    title: "Request Mode",
                    description: "Use Chat Completions for instruction-tuned models, or Completions " +
                        "for base models that continue a raw prompt.",
                    systemImage: "arrow.left.arrow.right"
                )
            }
            .pickerStyle(.menu)
            .settingsItem(.endpointAPIMode)

            LabeledContent {
                HStack(spacing: 8) {
                    SecureField("Optional", text: $endpointAPIKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)

                    if !endpointAPIKeyDraft.isEmpty {
                        Button("Clear") {
                            endpointAPIKeyDraft = ""
                            do {
                                try suggestionSettings.saveOpenAICompatibleAPIKey(nil)
                                endpointCredentialError = nil
                            } catch {
                                endpointCredentialError = error.localizedDescription
                            }
                        }
                    }
                }
            } label: {
                SettingsRowLabel(
                    title: "API Key",
                    description: "Optional bearer token stored in Keychain. Ollama does not require one.",
                    systemImage: "key"
                )
            }
            .settingsItem(.endpointAPIKey)

            LabeledContent {
                Text(openAICompatibleConnectionModel.state.summary)
                    .foregroundStyle(
                        openAICompatibleConnectionModel.state.failureDetail == nil
                            ? Color.secondary : Color.orange
                    )
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                SettingsRowLabel(
                    title: "Server Status",
                    description: "Whether Cotabby can reach this server and list its models.",
                    systemImage: "info.circle"
                )
            }
            .settingsItem(.endpointStatus)

            if let warning = endpointPrivacyWarning {
                SettingsCalloutView(callout: SettingsPaneCallout(tone: .warning, message: warning))
            }
            if let endpointCredentialError {
                SettingsCalloutView(
                    callout: SettingsPaneCallout(tone: .warning, message: endpointCredentialError)
                )
            }
        }

        Section("Model") {
            if !openAICompatibleConnectionModel.models.isEmpty {
                Picker(selection: endpointModelBinding) {
                    ForEach(openAICompatibleConnectionModel.models) { model in
                        Text(model.id).tag(model.id)
                    }
                    if !suggestionSettings.openAICompatibleModelName.isEmpty,
                       !openAICompatibleConnectionModel.models.contains(where: {
                           $0.id == suggestionSettings.openAICompatibleModelName
                       }) {
                        Text(suggestionSettings.openAICompatibleModelName)
                            .tag(suggestionSettings.openAICompatibleModelName)
                    }
                } label: {
                    SettingsRowLabel(
                        title: "Available Models",
                        description: "Models returned by the server's /v1/models endpoint.",
                        systemImage: "shippingbox"
                    )
                }
                .pickerStyle(.menu)
            }

            LabeledContent {
                TextField("Model identifier", text: endpointModelBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
            } label: {
                SettingsRowLabel(
                    title: "Model Name",
                    description: "The exact model identifier sent with every request. You can enter " +
                        "one manually when model discovery is unavailable.",
                    systemImage: "text.cursor"
                )
            }
            .settingsItem(.endpointModel)
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
        case .openAICompatible:
            do {
                let configuration = try suggestionSettings.openAICompatibleConfiguration
                guard !configuration.modelName.isEmpty else {
                    return SettingsPaneCallout(
                        tone: .warning,
                        message: OpenAICompatibleEndpointError.emptyModelName.localizedDescription
                    )
                }
            } catch {
                return SettingsPaneCallout(tone: .warning, message: error.localizedDescription)
            }
            guard let detail = openAICompatibleConnectionModel.state.failureDetail else { return nil }
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

    private var endpointBaseURLBinding: Binding<String> {
        Binding(
            get: { suggestionSettings.openAICompatibleBaseURL },
            set: { value in
                suggestionSettings.setOpenAICompatibleBaseURL(value)
                openAICompatibleConnectionModel.invalidate()
            }
        )
    }

    private var endpointModelBinding: Binding<String> {
        Binding(
            get: { suggestionSettings.openAICompatibleModelName },
            set: { suggestionSettings.setOpenAICompatibleModelName($0) }
        )
    }

    private var endpointAPIModeBinding: Binding<OpenAICompatibleAPIMode> {
        Binding(
            get: { suggestionSettings.openAICompatibleAPIMode },
            set: { suggestionSettings.setOpenAICompatibleAPIMode($0) }
        )
    }

    private var endpointPrivacyWarning: String? {
        (try? suggestionSettings.openAICompatibleConfiguration)?.privacyWarning
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

    private func loadEndpointAPIKey() {
        do {
            endpointAPIKeyDraft = try suggestionSettings.openAICompatibleAPIKey() ?? ""
            endpointCredentialError = nil
        } catch {
            endpointCredentialError = error.localizedDescription
        }
    }

    private func refreshEndpointModels() {
        Task {
            do {
                try suggestionSettings.saveOpenAICompatibleAPIKey(endpointAPIKeyDraft)
                endpointCredentialError = nil
                let configuration = try suggestionSettings.openAICompatibleConfiguration
                await openAICompatibleConnectionModel.refresh(
                    configuration: configuration,
                    apiKey: endpointAPIKeyDraft
                )
                if suggestionSettings.openAICompatibleModelName.isEmpty,
                   openAICompatibleConnectionModel.models.count == 1,
                   let onlyModel = openAICompatibleConnectionModel.models.first {
                    suggestionSettings.setOpenAICompatibleModelName(onlyModel.id)
                }
            } catch {
                endpointCredentialError = error.localizedDescription
                openAICompatibleConnectionModel.setFailure(error.localizedDescription)
            }
        }
    }
}
