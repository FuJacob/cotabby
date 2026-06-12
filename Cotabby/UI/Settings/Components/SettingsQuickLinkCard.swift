import SwiftUI

/// File overview:
/// One Home quick-link card: an icon tile, a title, a one-line caption, and a chevron that walks
/// in on hover. The whole card is a button that opens its pane. Hover lift is kept subtle (a
/// hairline tint and a 1pt rise, no scaling) so a grid of six never feels like a game menu.
struct SettingsQuickLinkCard: View {
    let category: SettingsCategory
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SettingsIconTile(systemImage: category.systemImage, tint: category.tint, size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(category.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovering ? 1 : 0)
                    .offset(x: isHovering ? 0 : -4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isHovering ? category.tint.opacity(0.35) : Color.primary.opacity(0.07),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: .black.opacity(isHovering ? 0.10 : 0.04),
                radius: isHovering ? 6 : 2,
                y: isHovering ? 3 : 1
            )
            .offset(y: isHovering ? -1 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel("\(category.label) settings")
        .accessibilityHint(category.summary)
    }
}
