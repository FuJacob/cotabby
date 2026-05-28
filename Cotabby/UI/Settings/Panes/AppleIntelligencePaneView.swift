import SwiftUI

/// File overview:
/// "Apple Intelligence" sub-pane. Shows availability detail for the on-device Foundation Models
/// path and offers a one-tap affordance to switch to this engine when the user is currently on the
/// Open Source engine. The engine picker itself lives in the parent overview pane, not here.
struct AppleIntelligencePaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var foundationModelAvailabilityService: FoundationModelAvailabilityService

    var body: some View {
        SettingsPaneScaffold(callout: callout) {
            Section("Apple Intelligence") {
                if !isSelectedEngine {
                    LabeledContent {
                        Button("Switch to Apple Intelligence") {
                            suggestionSettings.selectEngine(.appleIntelligence)
                        }
                        .controlSize(.regular)
                    } label: {
                        Text("Currently using the Open Source engine. Switch to use Apple Intelligence instead.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                LabeledContent("Availability") {
                    Text(foundationModelAvailabilityService.userVisibleMessage)
                        .foregroundStyle(foundationModelAvailabilityService.isAvailable ? .green : .orange)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { foundationModelAvailabilityService.refresh() }
    }

    private var isSelectedEngine: Bool {
        suggestionSettings.selectedEngine == .appleIntelligence
    }

    /// Only surface a callout when the user is on this engine *and* it is currently unavailable.
    /// If they are on the other engine the pane is informational and no warning is warranted.
    private var callout: SettingsPaneCallout? {
        guard isSelectedEngine, !foundationModelAvailabilityService.isAvailable else {
            return nil
        }
        return SettingsPaneCallout(
            tone: .warning,
            message: foundationModelAvailabilityService.userVisibleMessage
        )
    }
}
