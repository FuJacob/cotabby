import Foundation
import SwiftUI

/// Apple Intelligence availability presentation.
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
                        "to load. Uses the model's memory (several GB) while Apple Intelligence is selected.",
                    systemImage: "memorychip"
                )
            }
            .disabled(!suggestionSettings.isAppleLanguageFallbackEnabled)

            // The Open Source section is hidden while Apple Intelligence is the engine, so the
            // fallback model is chosen here. It is the same selection the Open Source engine uses:
            // the local runtime holds one model at a time.
            if runtimeModel.availableModels.isEmpty {
                Text("No downloaded models were found, so there is nothing to fall back to. " +
                    "Switch the engine to Open Source to download one.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Picker(selection: selectedModelBinding) {
                    ForEach(runtimeModel.availableModels) { model in
                        Text(model.displayName).tag(model.filename)
                    }
                } label: {
                    SettingsRowLabel(
                        title: "Fallback Model",
                        description: "The downloaded model used when Apple Intelligence can't handle the " +
                            "language. It is also your Open Source engine's model.",
                        systemImage: "shippingbox"
                    )
                }
                .disabled(!suggestionSettings.isAppleLanguageFallbackEnabled
                    || suggestionSettings.isPowerBasedModelSwitchingEnabled)
                .settingsItem(.appleLanguageFallbackModel)
            }
        }
    }

    /// The model the fallback uses: the selected Open Source model. The local runtime holds one
    /// model at a time, so the fallback cannot use a different one without swapping it in.
    private var fallbackModelName: String {
        runtimeModel.selectedModelFilename.map { ($0 as NSString).deletingPathExtension } ?? "your Open Source model"
    }
}
