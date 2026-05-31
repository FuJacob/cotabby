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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
