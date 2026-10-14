import SwiftUI

/// Settings → Rewrite: which model rewrites selected text (this Mac, or a cloud service such as
/// Claude or GPT with the user's key and a model picked from the service's own list), and whether a
/// button appears on selection. Presentation only: values live in
/// `RewritePreferencesStore`, each service's key in its own Keychain item (`RewriteCredentialVault`),
/// and the model list comes from `RewriteModelListService`.
struct RewritePaneView: View {
    @ObservedObject var preferences: RewritePreferencesStore
    let credentials: RewriteCredentialVault
    let modelList: RewriteModelListService
    let usesAppleIntelligence: Bool

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
                    Text(localProviderLabel).tag(RewriteProviderKind.local)
                    Text("API model").tag(RewriteProviderKind.api)
                } label: {
                    SettingsRowLabel(title: "Rewrite Model",
                                     description: "Local runs on this Mac. An API model usually rewrites better, "
                                         + "but the selected text is sent to it.",
                                     systemImage: "cpu")
                }
                .settingsItem(.rewriteProvider)

                if preferences.preferences.provider == .api {
                    Picker("Service", selection: Binding(get: { preferences.preferences.cloudProvider }, set: switchService)) {
                        ForEach(RewriteCloudProvider.allCases, id: \.self) { service in
                            Text(service.displayName).tag(service)
                        }
                    }
                    if preferences.preferences.cloudProvider == .custom {
                        TextField("Base URL (e.g. https://gateway.example.com/v1)",
                                  text: Binding(get: { preferences.preferences.apiBaseURL }, set: preferences.setAPIBaseURL))
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

    /// The local option names the model it will use: Apple Intelligence when available, else the
    /// Open Source base model, whose rewrites are weaker.
    private var localProviderLabel: String {
        usesAppleIntelligence ? "Local (Apple Intelligence)" : "Local (Cotabby's model — basic quality)"
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
                guard preferences.preferences.cloudProvider == service else { return }
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
