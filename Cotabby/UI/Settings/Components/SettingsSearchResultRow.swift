import SwiftUI

/// File overview:
/// One settings search hit, shared by the sidebar's result list (compact) and the Home hero
/// search (full, with summary and pane breadcrumb). The icon tile carries the destination pane's
/// tint with the item's own symbol, so a result simultaneously says what it is and where it lives.
struct SettingsSearchResultRow: View {
    enum Style {
        /// Single line for the narrow sidebar: tile, title, pane name.
        case compact
        /// Two lines for the Home hero search: tile, title plus summary, trailing pane chip.
        case full
    }

    let item: SettingsItem
    var style: Style = .compact

    var body: some View {
        HStack(spacing: 10) {
            SettingsIconTile(
                systemImage: item.systemImage,
                tint: item.category.tint,
                size: style == .full ? 28 : 20
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .lineLimit(1)
                if style == .full {
                    Text(item.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if style == .full {
                paneChip
            } else {
                Text(item.category.label)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), in \(item.category.label)")
    }

    private var paneChip: some View {
        HStack(spacing: 3) {
            Text(item.category.label)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}
