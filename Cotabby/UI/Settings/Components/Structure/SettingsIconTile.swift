import SwiftUI

/// File overview:
/// The System Settings-style icon tile: a white SF Symbol on a tinted, continuously rounded
/// square with a soft top-to-bottom gradient. One component drawn at three scales keeps the
/// sidebar, search results, and Home quick links visually related, so a category reads as the
/// same object everywhere it appears.
struct SettingsIconTile: View {
    let systemImage: String
    let tint: Color
    /// Edge length of the tile. The symbol and corner radius scale from it so callers only
    /// choose a size, never a matching radius/font pair.
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.52, weight: .medium))
            .foregroundStyle(.white)
            // White symbols disappear into pale tints (yellow especially) without a touch of
            // depth; the hairline shadow keeps the glyph legible on every tile color.
            .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.85), tint],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
            .accessibilityHidden(true)
    }
}
