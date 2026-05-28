import SwiftUI

/// File overview:
/// Parent overview pane for the "Engine & Model" group. Owns the engine picker (the only place
/// the user can switch engines), shows the high-level status of the current choice, and points
/// to the two sub-rows in the sidebar for engine-specific options.
///
/// Why the picker lives only here:
/// Having a picker in both sub-panes would mean the same control writes the same setting from two
/// places. Keeping it on the parent overview makes the engine choice a single source of truth and
/// keeps each sub-pane focused on the engine it represents.
struct EngineAndModelPaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var foundationModelAvailabilityService: FoundationModelAvailabilityService
    @ObservedObject var runtimeModel: RuntimeBootstrapModel

    var body: some View {
        SettingsPaneScaffold {
            Section("Engine") {
                Picker("Engine", selection: selectedEngineBinding) {
                    ForEach(SuggestionEngineKind.allCases) { engine in
                        Text(engine.displayLabel).tag(engine)
                    }
                }

                switch suggestionSettings.selectedEngine {
                case .appleIntelligence:
                    LabeledContent("Availability") {
                        Text(foundationModelAvailabilityService.userVisibleMessage)
                            .foregroundStyle(foundationModelAvailabilityService.isAvailable ? .green : .orange)
                    }
                case .llamaOpenSource:
                    LabeledContent("Runtime") {
                        Text(runtimeModel.state.summary)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Engine-specific options live under the sub-rows in the sidebar:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Label("Apple Intelligence — on-device availability and status.", systemImage: "apple.logo")
                        .font(.callout)
                    Label("Open Source — pick or download a local GGUF model.", systemImage: "shippingbox.fill")
                        .font(.callout)
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear { foundationModelAvailabilityService.refresh() }
    }

    private var selectedEngineBinding: Binding<SuggestionEngineKind> {
        Binding(
            get: { suggestionSettings.selectedEngine },
            set: { suggestionSettings.selectEngine($0) }
        )
    }
}
