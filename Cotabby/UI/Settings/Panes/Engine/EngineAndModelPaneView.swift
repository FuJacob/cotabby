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

    @State var pendingDeletionModel: RuntimeModelOption?
    @State var endpointAPIKeyDraft = ""
    @State var endpointCredentialError: String?
    /// The LM Studio models directory if it exists, probed once in `onAppear` so the filesystem
    /// `fileExists` check never runs on the SwiftUI render path. Nil disables the LM Studio toggle.
    @State var lmStudioModelsURL: URL?
    /// Whether to also scan the user's LM Studio library. Persisted via the same key the locator
    /// reads, so the toggle and the model scan stay in sync. LM Studio models are an additive,
    /// read-only source; Cotabby's own folder is always scanned and is always the download target.
    @AppStorage(BundledRuntimeLocator.lmStudioSourceEnabledKey) var lmStudioSourceEnabled = false

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
}
