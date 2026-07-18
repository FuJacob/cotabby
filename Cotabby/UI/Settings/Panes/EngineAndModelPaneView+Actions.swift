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

    var selectedEngineBinding: Binding<SuggestionEngineKind> {
        Binding(
            get: { suggestionSettings.selectedEngine },
            set: { suggestionSettings.selectEngine($0) }
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

    var endpointBaseURLBinding: Binding<String> {
        Binding(
            get: { suggestionSettings.openAICompatibleBaseURL },
            set: { value in
                suggestionSettings.setOpenAICompatibleBaseURL(value)
                openAICompatibleConnectionModel.invalidate()
            }
        )
    }

    var endpointModelBinding: Binding<String> {
        Binding(
            get: { suggestionSettings.openAICompatibleModelName },
            set: { suggestionSettings.setOpenAICompatibleModelName($0) }
        )
    }

    var endpointAPIModeBinding: Binding<OpenAICompatibleAPIMode> {
        Binding(
            get: { suggestionSettings.openAICompatibleAPIMode },
            set: { suggestionSettings.setOpenAICompatibleAPIMode($0) }
        )
    }

    var endpointPrivacyWarning: String? {
        (try? suggestionSettings.openAICompatibleConfiguration)?.privacyWarning
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
        if case .ready = openAICompatibleConnectionModel.state {
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

    /// Reset is intentionally local to the address. The selected model and Keychain credential
    /// remain untouched because they may still be valid for the default Ollama server. Invalidating
    /// discovery makes the status honest until the user explicitly connects again.
    func resetEndpointBaseURL() {
        suggestionSettings.setOpenAICompatibleBaseURL(
            OpenAICompatibleEndpointConfiguration.defaultBaseURLString
        )
        openAICompatibleConnectionModel.invalidate()
    }

    func loadEndpointAPIKey() {
        do {
            endpointAPIKeyDraft = try suggestionSettings.openAICompatibleAPIKey() ?? ""
            endpointCredentialError = nil
        } catch {
            endpointCredentialError = error.localizedDescription
        }
    }

    func refreshEndpointModels() {
        Task {
            do {
                try suggestionSettings.saveOpenAICompatibleAPIKey(endpointAPIKeyDraft)
                endpointCredentialError = nil
                let configuration = try suggestionSettings.openAICompatibleConfiguration
                await openAICompatibleConnectionModel.refresh(
                    configuration: configuration,
                    apiKey: endpointAPIKeyDraft
                )
                if let preferredModel = OpenAICompatibleModelSelectionResolver.preferredSelection(
                    currentSelection: suggestionSettings.openAICompatibleModelName,
                    discoveredModels: openAICompatibleConnectionModel.models
                ), preferredModel != suggestionSettings.openAICompatibleModelName {
                    suggestionSettings.setOpenAICompatibleModelName(preferredModel)
                }
            } catch {
                endpointCredentialError = error.localizedDescription
                openAICompatibleConnectionModel.setFailure(error.localizedDescription)
            }
        }
    }
}
