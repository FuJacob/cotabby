import SwiftUI

/// Power-source profile controls shared by every engine.
/// These members are internal because Swift extensions in separate files cannot share lexical `private` access;
/// the owning view itself remains module-internal.
extension EngineAndModelPaneView {
// MARK: - Power

    /// Engine-level section (shown for any engine) that lets the user pick a different profile,
    /// Apple Intelligence or a specific local model, for battery vs. plugged-in power. Apple
    /// Intelligence is offered only when it is actually available on this Mac.
    @ViewBuilder
    var powerSection: some View {
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
    func powerProfilePicker(
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

    var batteryProfileBinding: Binding<PowerProfile> {
        Binding(
            get: { powerProfileForDisplay(suggestionSettings.batteryProfile) },
            set: { suggestionSettings.setBatteryProfile($0) }
        )
    }

    var pluggedInProfileBinding: Binding<PowerProfile> {
        Binding(
            get: { powerProfileForDisplay(suggestionSettings.pluggedInProfile) },
            set: { suggestionSettings.setPluggedInProfile($0) }
        )
    }

    /// Falls a not-yet-chosen local profile back to the currently selected model so the picker shows
    /// a concrete row instead of an empty selection, mirroring the primary model picker's fallback.
    func powerProfileForDisplay(_ profile: PowerProfile) -> PowerProfile {
        if case .llama(let filename) = profile, filename.isEmpty {
            return .llama(filename: runtimeModel.selectedModelFilename ?? "")
        }
        if case .openAICompatible(let modelName) = profile, modelName.isEmpty {
            return .openAICompatible(modelName: suggestionSettings.openAICompatibleModelName)
        }

        return profile
    }

    var endpointPowerModels: [String] {
        var names = openAICompatibleConnectionModel.models.map(\.id)
        let configured = suggestionSettings.openAICompatibleModelName
        if !configured.isEmpty, !names.contains(configured) {
            names.append(configured)
        }
        return names
    }
}
