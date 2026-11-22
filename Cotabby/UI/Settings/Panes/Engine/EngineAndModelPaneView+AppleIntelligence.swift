import SwiftUI

/// Apple Intelligence availability plus the language-fallback controls (fallback switch, keep-loaded
/// switch, and fallback model picker).
/// These members are internal because Swift extensions in separate files cannot share lexical `private` access;
/// the owning view itself remains module-internal.
extension EngineAndModelPaneView {
// MARK: - Apple Intelligence

    @ViewBuilder
    var appleIntelligenceSections: some View {
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

            Toggle(isOn: Binding(
                get: { suggestionSettings.isAppleLanguageFallbackEnabled },
                set: { suggestionSettings.setAppleLanguageFallbackEnabled($0) }
            )) {
                SettingsRowLabel(
                    title: "Fall Back to Open Source Model",
                    description: "When Apple Intelligence doesn't support the language you're writing in, " +
                        "suggest with \(fallbackModelName) instead. Turn off to get no suggestion in those languages.",
                    systemImage: "arrow.triangle.branch"
                )
            }
            .settingsItem(.appleLanguageFallback)

            Toggle(isOn: Binding(
                get: { suggestionSettings.keepsFallbackModelLoaded },
                set: { suggestionSettings.setKeepsFallbackModelLoaded($0) }
            )) {
                SettingsRowLabel(
                    title: "Keep Fallback Model Loaded",
                    description: "Load the fallback model in advance so its first suggestion doesn't wait for it " +
                        "to load. Uses the model's memory (up to several GB) while Apple Intelligence is selected.",
                    systemImage: "memorychip"
                )
            }
            .disabled(!suggestionSettings.isAppleLanguageFallbackEnabled)
            .settingsItem(.keepFallbackModelLoaded)

            // The Open Source section is hidden while Apple Intelligence is the engine, so the
            // fallback model is chosen here. It is the same selection the Open Source engine uses:
            // the local runtime holds one model at a time.
            if runtimeModel.availableModels.isEmpty {
                // Only worth a warning while the fallback is on; with it off, no model is needed.
                if suggestionSettings.isAppleLanguageFallbackEnabled {
                    Text("No downloaded models were found, so there is nothing to fall back to. " +
                        "Switch the engine to Open Source to download one.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Picker(selection: fallbackModelBinding) {
                    ForEach(runtimeModel.availableModels) { model in
                        Text(model.displayName).tag(model.filename)
                    }
                } label: {
                    SettingsRowLabel(
                        title: "Fallback Model",
                        description: suggestionSettings.isPowerBasedModelSwitchingEnabled
                            ? "Set automatically by power source. Turn off power-based switching in the " +
                                "Power section to choose it here."
                            : "The downloaded model used when Apple Intelligence can't handle the " +
                                "language. It is also your Open Source engine's model.",
                        systemImage: "shippingbox"
                    )
                }
                // Disabled under power-based switching for the same reason as the Open Source
                // picker: the power profiles own the selected model and would revert a pick here.
                .disabled(!suggestionSettings.isAppleLanguageFallbackEnabled
                    || suggestionSettings.isPowerBasedModelSwitchingEnabled)
                .settingsItem(.appleLanguageFallbackModel)
            }
        }
    }

    /// The model the fallback uses: the selected Open Source model. The local runtime holds one
    /// model at a time, so the fallback cannot use a different one without swapping it in. Uses the
    /// catalog name so the toggle names the model the same way the picker below lists it.
    private var fallbackModelName: String {
        runtimeModel.selectedModelFilename.map { RuntimeModelCatalog.displayName(for: $0) } ?? "your Open Source model"
    }

    /// Shares the Open Source selection, but picking a model here must not load it on its own.
    /// While the runtime is meant to stay unloaded ("Keep Fallback Model Loaded" off), the choice is
    /// only recorded and the next fallback loads it; `selectedModelBinding` would load several GB
    /// the user asked not to keep in memory. When the runtime is kept loaded, swap the model now so
    /// the fallback stays ready.
    private var fallbackModelBinding: Binding<String> {
        Binding(
            get: { selectedModelBinding.wrappedValue },
            set: { filename in
                if suggestionSettings.keepsLocalRuntimeLoaded {
                    Task { await runtimeModel.selectModel(filename) }
                } else {
                    runtimeModel.selectModelWithoutLoading(filename)
                }
            }
        )
    }
}
