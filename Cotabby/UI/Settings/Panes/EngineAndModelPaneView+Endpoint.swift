import SwiftUI

/// OpenAI-compatible endpoint connection, credential, and model controls.
/// These members are internal because Swift extensions in separate files cannot share lexical `private` access;
/// the owning view itself remains module-internal.
extension EngineAndModelPaneView {
// MARK: - OpenAI-compatible endpoint

    /// Endpoint controls stay inside the unified engine pane. The connection model owns network
    /// state, the settings model owns durable non-secret values, and the API key draft only lives
    /// for this view's lifetime before an explicit Connect saves it to Keychain.
    @ViewBuilder
    var openAICompatibleSections: some View {
        Section("Connection") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsRowLabel(
                    title: "Server URL",
                    description: "The OpenAI-compatible server address. Cotabby adds /v1 when the " +
                        "address has no path; Ollama uses http://127.0.0.1:11434 by default.",
                    systemImage: "network"
                )

                HStack(spacing: 8) {
                    TextField(
                        "",
                        text: endpointBaseURLBinding,
                        prompt: Text(OpenAICompatibleEndpointConfiguration.defaultBaseURLString)
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(refreshEndpointModels)

                    Button(
                        endpointConnectButtonTitle,
                        action: refreshEndpointModels
                    )
                    .buttonStyle(.borderedProminent)
                    .disabled(openAICompatibleConnectionModel.state == .connecting)
                }

                HStack(spacing: 8) {
                    endpointConnectionStatus

                    Spacer(minLength: 8)

                    Button("Use Ollama Default", systemImage: "arrow.counterclockwise") {
                        resetEndpointBaseURL()
                    }
                    .disabled(
                        suggestionSettings.openAICompatibleBaseURL
                            == OpenAICompatibleEndpointConfiguration.defaultBaseURLString
                    )
                }
            }
            .settingsItem(.endpointBaseURL)

            LabeledContent {
                HStack(spacing: 8) {
                    SecureField("", text: $endpointAPIKeyDraft, prompt: Text("Paste API key"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 200, idealWidth: 260, maxWidth: 300)

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
            LabeledContent {
                HStack(spacing: 6) {
                    TextField("", text: endpointModelBinding, prompt: Text("Enter model identifier"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 320)

                    Menu {
                        ForEach(openAICompatibleConnectionModel.models) { model in
                            Button(model.id) {
                                suggestionSettings.setOpenAICompatibleModelName(model.id)
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                            .frame(width: 18, height: 18)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(openAICompatibleConnectionModel.models.isEmpty)
                    .help(endpointModelMenuHelp)
                    .accessibilityLabel("Choose a discovered model")
                }
            } label: {
                SettingsRowLabel(
                    title: "Model",
                    description: "Choose a model returned by the server or enter its identifier manually.",
                    systemImage: "shippingbox"
                )
            }
            .settingsItem(.endpointModel)

            Picker(selection: endpointAPIModeBinding) {
                Text("Chat Completions").tag(OpenAICompatibleAPIMode.chatCompletions)
                Text("Text Completions").tag(OpenAICompatibleAPIMode.completions)
            } label: {
                SettingsRowLabel(
                    title: "API Format",
                    description: "Chat uses /v1/chat/completions (recommended). Text uses " +
                        "/v1/completions for base models that continue a raw prompt.",
                    systemImage: "arrow.left.arrow.right"
                )
            }
            .pickerStyle(.segmented)
            .settingsItem(.endpointAPIMode)
        }
    }

    @ViewBuilder
    func installedModelRow(_ model: RuntimeModelOption) -> some View {
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
}
