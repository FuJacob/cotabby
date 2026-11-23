import SwiftUI

/// Shared callout, bindings, and user actions for the unified engine pane.
/// These members are internal because Swift extensions in separate files cannot share lexical `private` access;
/// the owning view itself remains module-internal.
extension EngineAndModelPaneView {
// MARK: - Callout

    /// Surface the engine's failure mode at the top of the pane so it sits next to the controls
    /// that fix it. Only the selected engine surfaces a warning; the inactive engine's status is
    /// informational and doesn't warrant alarming the user.
    var callout: SettingsPaneCallout? {
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
            // Reports an unapproved server too, so the pane says why nothing is being sent instead of
            // failing silently.
            if let configurationError = suggestionSettings.openAICompatibleConfigurationError {
                return SettingsPaneCallout(tone: .warning, message: configurationError)
            }
            guard let detail = openAICompatibleConnectionModel.state.failureDetail else { return nil }
            return SettingsPaneCallout(tone: .warning, message: detail)
        }
    }

    // MARK: - Bindings & actions

    var selectedEngineBinding: Binding<SuggestionEngineKind> {
        Binding(
            get: { suggestionSettings.selectedEngine },
            set: { engine in
                // Second line of defense behind the disabled menu item: never persist an engine the
                // Mac cannot run, even if a future picker style ignores `selectionDisabled`.
                guard isEngineSelectable(engine) else { return }
                suggestionSettings.selectEngine(engine)
            }
        )
    }

    func isEngineSelectable(_ engine: SuggestionEngineKind) -> Bool {
        SuggestionEngineSelectionPolicy.isSelectable(
            engine,
            foundationModelAvailable: foundationModelAvailabilityService.isAvailable
        )
    }

    var selectedModelBinding: Binding<String> {
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

    /// What the Server URL field shows: the uncommitted draft while there is one, else the saved
    /// address. Keeping the draft in view state means a half-typed or newly pasted address never
    /// receives a request, and the API key never follows an edit until the user presses Connect.
    var endpointBaseURLText: String {
        endpointBaseURLDraft ?? suggestionSettings.openAICompatibleBaseURL
    }

    var endpointHasUncommittedBaseURL: Bool {
        endpointBaseURLDraft != nil
    }

    var endpointBaseURLBinding: Binding<String> {
        Binding(
            get: { endpointBaseURLText },
            set: { value in
                endpointBaseURLDraft = value == suggestionSettings.openAICompatibleBaseURL ? nil : value
            }
        )
    }

    /// Describes the address in the field, not the saved one, so the disclosure is on screen before
    /// the user presses Connect to approve that server.
    var endpointPrivacyWarning: String? {
        (try? OpenAICompatibleEndpointConfiguration(
            baseURLString: endpointBaseURLText,
            modelName: suggestionSettings.openAICompatibleModelName,
            apiMode: suggestionSettings.openAICompatibleAPIMode
        ))?.privacyWarning
    }

    /// Compact feedback stays beside the connection action instead of repeating the URL in a second
    /// card. This view has no independent lifetime; the endpoint connection model drives every state.
    var endpointConnectionStatus: some View {
        HStack(spacing: 6) {
            Group {
                if openAICompatibleConnectionModel.state == .connecting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: endpointConnectionSymbol)
                        .foregroundStyle(endpointConnectionColor)
                }
            }
            .frame(width: 14)

            Text(openAICompatibleConnectionModel.state.summary)
                .font(.caption.weight(.medium))
                .foregroundStyle(endpointConnectionColor)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Server status")
        .accessibilityValue("\(openAICompatibleConnectionModel.state.summary), \(endpointDisplayURL)")
        .settingsItem(.endpointStatus)
    }

    var endpointConnectButtonTitle: String {
        if !endpointHasUncommittedBaseURL, case .ready = openAICompatibleConnectionModel.state {
            return "Refresh"
        }
        return "Connect"
    }

    var endpointConnectionSymbol: String {
        switch openAICompatibleConnectionModel.state {
        case .idle: return "circle.dashed"
        case .connecting: return "circle.dashed"
        case .ready: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var endpointConnectionColor: Color {
        switch openAICompatibleConnectionModel.state {
        case .idle, .connecting: return .secondary
        case .ready: return .green
        case .failed: return .orange
        }
    }

    var endpointDisplayURL: String {
        if let configuration = try? suggestionSettings.openAICompatibleConfiguration {
            return configuration.baseURL.absoluteString
        }
        let enteredURL = suggestionSettings.openAICompatibleBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return enteredURL.isEmpty ? "No endpoint configured" : enteredURL
    }

    var endpointModelMenuHelp: String {
        if openAICompatibleConnectionModel.models.isEmpty {
            return "Connect to load models, or enter an identifier manually."
        }
        return "Choose from \(openAICompatibleConnectionModel.models.count) discovered models."
    }

    var pendingDeletionAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletionModel != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletionModel = nil
                }
            }
        )
    }

    func deleteModel(_ model: RuntimeModelOption) {
        modelDownloadManager.deleteModel(filename: model.filename)
        runtimeModel.refreshAvailableModels()
        pendingDeletionModel = nil
    }

    func refreshModels() {
        modelDownloadManager.refreshModelStates()
        runtimeModel.refreshAvailableModels()
    }

    /// Reset only fills the field with the default Ollama address. Like any other address it takes
    /// effect on Connect, which is what approves that server. The selected model and Keychain
    /// credential stay untouched because they may still be valid for the default Ollama server.
    func resetEndpointBaseURL() {
        let defaultURL = OpenAICompatibleEndpointConfiguration.defaultBaseURLString
        endpointBaseURLDraft = suggestionSettings.openAICompatibleBaseURL == defaultURL ? nil : defaultURL
    }

    func loadEndpointAPIKey() {
        do {
            endpointAPIKeyDraft = try suggestionSettings.openAICompatibleAPIKey() ?? ""
            endpointCredentialError = nil
        } catch {
            endpointCredentialError = error.localizedDescription
        }
    }

    /// Connect (button or Return) is the only action that changes which server receives text and
    /// the API key. It approves the typed address's server in the Keychain, commits the address,
    /// saves the key draft, and only then sends the first request. Pressing it is the user's
    /// confirmation, including for a plain-HTTP LAN server whose warning says the key is unencrypted.
    func connectEndpoint() {
        let baseURL = endpointBaseURLText
        Task {
            do {
                let configuration = try suggestionSettings.approveOpenAICompatibleEndpoint(baseURLString: baseURL)
                endpointBaseURLDraft = nil
                try suggestionSettings.saveOpenAICompatibleAPIKey(endpointAPIKeyDraft)
                endpointCredentialError = nil
                await openAICompatibleConnectionModel.refresh(
                    configuration: configuration,
                    apiKey: endpointAPIKeyDraft
                )
                adoptPreferredEndpointModel()
            } catch {
                endpointCredentialError = error.localizedDescription
                openAICompatibleConnectionModel.setFailure(error.localizedDescription)
            }
        }
    }

    /// Automatic discovery (the pane appears, or the engine is switched here) only talks to the
    /// server the user already approved. An unapproved server gets no request; the failure state
    /// tells the user to press Connect instead.
    func refreshApprovedEndpointModels() {
        Task {
            do {
                let configuration = try suggestionSettings.openAICompatibleApprovedConfiguration
                let apiKey = try suggestionSettings.openAICompatibleAPIKey()
                await openAICompatibleConnectionModel.refresh(configuration: configuration, apiKey: apiKey)
                adoptPreferredEndpointModel()
            } catch {
                openAICompatibleConnectionModel.setFailure(error.localizedDescription)
            }
        }
    }

    func adoptPreferredEndpointModel() {
        if let preferredModel = OpenAICompatibleModelSelectionResolver.preferredSelection(
            currentSelection: suggestionSettings.openAICompatibleModelName,
            discoveredModels: openAICompatibleConnectionModel.models
        ), preferredModel != suggestionSettings.openAICompatibleModelName {
            suggestionSettings.setOpenAICompatibleModelName(preferredModel)
        }
    }
}
