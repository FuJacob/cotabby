import SwiftUI

/// Two-line label slot used inside Settings `Toggle`, `Picker`, and `LabeledContent` rows so the
/// title row is followed by a one-sentence description in secondary text. Mirrors the macOS System
/// Settings look so a novice user can understand each control without hovering for a tooltip.
///
/// Always-visible subtext beats `.help()` here because tooltips are invisible to users who don't
/// know to hover; the cost is one extra line of vertical space per row, which we accept.
struct SettingsRowLabel: View {
    let title: String
    let description: String
    /// Optional leading SF Symbol. Rendered monochrome in secondary color so it aids scanning
    /// without competing with the control on the trailing edge. Decorative: hidden from VoiceOver
    /// because the title already names the setting.
    var systemImage: String?

    init(title: String, description: String, systemImage: String? = nil) {
        self.title = title
        self.description = description
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .center)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
