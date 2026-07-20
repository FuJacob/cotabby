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
        }
    }
}
