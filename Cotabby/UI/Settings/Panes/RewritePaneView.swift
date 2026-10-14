import SwiftUI

/// Settings → Rewrite: which model rewrites selected text (the engine autocomplete uses, any other
/// autocomplete engine reusing its model, or a cloud service such as Claude or GPT with the user's
/// key and a model picked from the service's own list), and whether a button appears on selection.
/// Presentation only: values live in `RewritePreferencesStore`, each service's key in its own
/// Keychain item (`RewriteCredentialVault`), the model list comes from `RewriteModelListService`,
/// and which rows can run comes from `RewriteEngine`'s providers.
struct RewritePaneView: View {
    @ObservedObject var preferences: RewritePreferencesStore
    let credentials: RewriteCredentialVault
    let modelList: RewriteModelListService
    let engine: RewriteEngine
    /// Observed so the "Same as autocomplete" row, the endpoint disclosure and the MLX note follow
    /// autocomplete's engine and settings.
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    // Everything a row's availability is computed from. `engine.provider(for:).isAvailable` reads
    // plain state, so the pane observes the sources itself: an "(Unavailable)" row then re-enables
    // as soon as an MLX install, a model download or Apple Intelligence becomes ready.
    @ObservedObject var mlxToolchainProvisioner: MLXToolchainProvisioner
    @ObservedObject var mlxModelDownloader: MLXModelDownloader
    @ObservedObject var mlxServerManager: MLXServerManager
    @ObservedObject var foundationModelAvailabilityService: FoundationModelAvailabilityService
    @ObservedObject var runtimeModel: RuntimeBootstrapModel

    /// Models the service reported after "Load models"; empty until then.
    @State private var loadedModels: [String] = []
    @State private var modelListStatus: String?
    @State private var isLoadingModels = false

    @State private var apiKey = ""
    /// The key as last read from or written to the Keychain. Typing compares against it, so loading
    /// the key on appear does not count as an edit, and leaving the pane saves only real changes.
    @State private var savedAPIKey = ""
    /// The line under the key field: what the last save did. Nil until the first save attempt.
    @State private var keyStatus: String?
    @State private var keyStatusIsError = false
    /// The save scheduled 600 ms after the last keystroke; each edit cancels the previous one.
    @State private var pendingKeySave: Task<Void, Never>?

    var body: some View {
        SettingsPaneScaffold {
            Section {
                Toggle(isOn: Binding(get: { preferences.preferences.isEnabled }, set: preferences.setEnabled)) {
                    SettingsRowLabel(title: "Rewrite Selected Text",
                                     description: "Off: Cotabby ignores selections, with no wand, no "
                                         + "\(preferences.preferences.shortcutLabel) shortcut and no key tap.",
                                     systemImage: "wand.and.stars")
                }
                .settingsItem(.rewriteEnabled)
            }
            Section("Model") {
                Picker(selection: Binding(get: { preferences.preferences.provider }, set: preferences.setProvider)) {
                    ForEach(RewriteProviderKind.allCases, id: \.self) { kind in
                        Text(rowTitle(kind))
                            .tag(kind)
                            // Disables just this menu item (macOS 14+), like the engine picker.
                            .selectionDisabled(!isSelectable(kind))
                    }
                } label: {
                    SettingsRowLabel(title: "Rewrite Model",
                                     description: "Apple Intelligence, Open Source, Local Endpoint and MLX use the "
                                         + "model you set up for autocomplete; there is no separate rewrite model. "
                                         + "Instruction-following models (Apple Intelligence, chat models) rewrite "
                                         + "best; a base model gives basic-quality rewrites. An API model usually "
                                         + "rewrites better, but the selected text is sent to it.",
                                     systemImage: "cpu")
                }
                .settingsItem(.rewriteProvider)

                if let note = selectedNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                if let reason = selectedUnavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }
                if let host = endpointDisclosureHost {
                    Text("Rewrites go to the endpoint set up in Engine & Model: the selected text is sent to \(host).")
                        .font(.caption).foregroundStyle(.orange)
                }

                if preferences.preferences.provider == .api {
                    Picker("Service", selection: Binding(get: { preferences.preferences.cloudProvider }, set: switchService)) {
                        ForEach(RewriteCloudProvider.allCases, id: \.self) { service in
                            Text(service.displayName).tag(service)
                        }
                    }
                    if preferences.preferences.cloudProvider == .custom {
                        TextField("Base URL (e.g. https://gateway.example.com/v1)",
                                  text: Binding(get: { preferences.preferences.apiBaseURL }, set: setBaseURL))
                    }
                    HStack {
                        TextField("Model", text: Binding(get: { preferences.preferences.apiModelName }, set: preferences.setAPIModelName))
                        Menu("Choose") {
                            ForEach(modelChoices, id: \.self) { model in
                                Button(model) { preferences.setAPIModelName(model) }
                            }
                        }
                        .disabled(modelChoices.isEmpty)
                        .fixedSize()
                        Button(isLoadingModels ? "Loading…" : "Load models") { loadModels() }
                            .disabled(isLoadingModels)
                    }
                    if let modelListStatus {
                        Text(modelListStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    SecureField("API key", text: $apiKey)
                        .onSubmit { saveAPIKey() }
                    Button("Save API Key") { saveAPIKey() }
                    if let keyStatus {
                        Text(keyStatus).font(.caption).foregroundStyle(keyStatusIsError ? .red : .secondary)
                    }
                    if let host = offDeviceHost {
                        Text("The selected text is sent to \(host) when you rewrite.").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Section("Selection") {
                Toggle(isOn: Binding(get: { preferences.preferences.showsButtonOnSelection }, set: preferences.setShowsButtonOnSelection)) {
                    SettingsRowLabel(title: "Show Button on Selection",
                                     description: "The Cotabby icon beside a field becomes a rewrite button when you "
                                         + "select text. \(preferences.preferences.shortcutLabel) opens the rewrite either way.",
                                     systemImage: "wand.and.stars")
                }
                .settingsItem(.rewriteButton)
            }
        }
        .onAppear { loadKey() }
        // Each edit restarts a 600 ms timer, so the key is saved once typing pauses, without a Save click.
        .onChange(of: apiKey) { _, newKey in
            pendingKeySave?.cancel()
            guard newKey != savedAPIKey else { return }
            pendingKeySave = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                saveAPIKey()
            }
        }
        // Leaving the pane saves at once, so a key typed in the last moment is not lost.
        .onDisappear {
            pendingKeySave?.cancel()
            pendingKeySave = nil
            if apiKey != savedAPIKey { saveAPIKey() }
        }
    }

    // MARK: - Rewrite Model rows

    private func rowTitle(_ kind: RewriteProviderKind) -> String {
        RewriteProviderRowPolicy.title(
            for: kind,
            autocompleteEngineLabel: suggestionSettings.selectedEngine.displayLabel,
            sameAsAutocompleteStaysOnDevice: engine.sameAsAutocompleteStaysOnDevice,
            isAvailable: engine.provider(for: kind).isAvailable
        )
    }

    private func isSelectable(_ kind: RewriteProviderKind) -> Bool {
        RewriteProviderRowPolicy.isSelectable(kind, isAvailable: engine.provider(for: kind).isAvailable)
    }

    /// The reason the selected choice cannot run, shown under the picker.
    private var selectedUnavailableReason: String? {
        let provider = engine.provider(for: preferences.preferences.provider)
        guard !provider.isAvailable else { return nil }
        return provider.unavailableReason ?? "This rewrite model isn't set up."
    }

    /// What the selected local choice runs on, when that is worth saying.
    private var selectedNote: String? {
        if preferences.preferences.provider == .sameAsAutocomplete, engine.sameAsAutocompleteStaysOnDevice {
            let fallback = engine.resolvedKind == .appleIntelligence ? "Apple Intelligence" : "Open Source"
            return "Autocomplete's endpoint is not on this Mac, so rewrites run on \(fallback) here. "
                + "Choose Local Endpoint to send them to the endpoint."
        }
        guard engine.resolvedKind == .mlx else { return nil }
        let model = suggestionSettings.mlxModelID
        return model.isEmpty ? nil : "Uses your MLX model: \(model)"
    }

    /// The LAN or public host an explicitly chosen Local Endpoint sends the selection to; nil when
    /// that endpoint is on this Mac. "Same as autocomplete" never resolves to such a host.
    private var endpointDisclosureHost: String? {
        guard engine.resolvedKind == .localEndpoint else { return nil }
        let provider = engine.provider(for: .localEndpoint)
        guard provider.isAvailable, provider.sendsOffDevice else { return nil }
        return provider.hostName
    }

    /// The host the selected text leaves the Mac for, or nil for a loopback URL (a local Ollama),
    /// which keeps the text on this Mac, the same rule the popup's disclosure follows.
    private var offDeviceHost: String? {
        guard let configuration = try? OpenAICompatibleEndpointConfiguration(
            baseURLString: preferences.preferences.effectiveBaseURL, modelName: "", apiMode: .chatCompletions
        ), configuration.hostScope != .loopback else { return nil }
        return configuration.baseURL.host
    }

    /// The models offered in "Choose": the service's own list once loaded, else its suggestions.
    private var modelChoices: [String] {
        loadedModels.isEmpty ? preferences.preferences.cloudProvider.suggestedModels : loadedModels
    }

    /// Changes service: saves a key still being typed for the old one, then shows the new one's key
    /// and forgets the old model list.
    private func switchService(_ service: RewriteCloudProvider) {
        if apiKey != savedAPIKey { saveAPIKey() }
        preferences.setCloudProvider(service)
        loadedModels = []
        modelListStatus = nil
        keyStatus = nil
        loadKey()
    }

    private func loadKey() {
        let stored = (try? credentials.store(for: preferences.preferences.cloudProvider).readAPIKey()) ?? ""
        savedAPIKey = stored
        apiKey = stored
    }

    /// Asks the service for the models this key can use.
    /// A new URL is a different server: its model list must be loaded again, so the old one goes.
    private func setBaseURL(_ value: String) {
        guard value != preferences.preferences.apiBaseURL else { return }
        preferences.setAPIBaseURL(value)
        loadedModels = []
        modelListStatus = nil
    }

    private func loadModels() {
        if apiKey != savedAPIKey { saveAPIKey() }
        let service = preferences.preferences.cloudProvider
        let baseURL = preferences.preferences.effectiveBaseURL
        let key = apiKey
        isLoadingModels = true
        modelListStatus = nil
        Task { @MainActor in
            defer { isLoadingModels = false }
            do {
                let models = try await modelList.models(for: service, baseURL: baseURL, apiKey: key)
                // The user may have switched service or edited the URL while the list loaded; a list
                // from another server must not be offered for this one.
                guard preferences.preferences.cloudProvider == service,
                      preferences.preferences.effectiveBaseURL == baseURL else { return }
                loadedModels = models
                modelListStatus = models.isEmpty ? "The service listed no models." : "\(models.count) models — pick one with Choose."
            } catch {
                modelListStatus = "Couldn't load models: \(error.localizedDescription)"
            }
        }
    }

    /// Writes the key to the current service's Keychain item (never to UserDefaults or logs) and
    /// reports the result under the field. The error text comes from the Keychain call itself.
    private func saveAPIKey() {
        pendingKeySave?.cancel()
        pendingKeySave = nil
        do {
            try credentials.store(for: preferences.preferences.cloudProvider).saveAPIKey(apiKey)
            savedAPIKey = apiKey
            keyStatus = "Key saved in the Keychain."
            keyStatusIsError = false
        } catch {
            keyStatus = "Couldn't save the key: \(error.localizedDescription)"
            keyStatusIsError = true
        }
    }
}
