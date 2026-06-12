import SwiftUI

/// File overview:
/// A key binding rendered as a physical keycap: top-lit gradient, hairline edge, and a hard
/// one-point ledge shadow that gives the key its height. Shared by the onboarding keys step and
/// the Settings Shortcuts pane so a binding looks like the same object on both surfaces. Pure
/// chrome; recording flows never enter here.
struct KeycapView: View {
    let label: String
    var fontSize: CGFloat = 13
    var minWidth: CGFloat = 44

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(label)
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minWidth: minWidth)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [Color(white: 0.26), Color(white: 0.19)]
                                : [Color.white, Color(white: 0.92)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(
                        color: .black.opacity(colorScheme == .dark ? 0.55 : 0.22),
                        radius: 0.5,
                        y: 1.5
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            .fixedSize()
    }
}
