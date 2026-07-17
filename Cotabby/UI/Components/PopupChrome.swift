import SwiftUI

/// File overview:
/// One shared visual language for every Cotabby surface that floats near the caret: the inline
/// emoji picker, the suggestion "popup" card (mirror mode), and the macro inline preview. Before
/// this they each carried their own `.regularMaterial` + border styling and drifted apart; routing
/// all three through `PopupTheme`/`PopupHUDChrome` keeps them identical and lets a restyle land in
/// one place.
///
/// The look is a *committed-dark* HUD: a deterministic charcoal gradient rather than an adaptive
/// material. Determinism is the point — the popup must read the same dark over a white Pages window
/// as over a black terminal, so it always looks like an ephemeral system overlay instead of a bright
/// card competing with the host document. (An adaptive material would invert to light over a light
/// host, which is exactly the "intrusive bright box" we are moving away from.)
enum PopupTheme {
    /// Shared corner radius. Continuous curvature; sized to look right on both the short single-line
    /// cards (~28pt tall) and the taller two-row emoji popup (~62pt) without going pill-round.
    static let cornerRadius: CGFloat = 10

    /// The dark backdrop. A subtle top-to-bottom gradient (lighter crown, darker base) reads as a
    /// lit surface rather than a flat black rectangle, which is what keeps it from looking cheap.
    static let backgroundGradient = LinearGradient(
        colors: [Color(white: 0.17), Color(white: 0.11)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Hairline edge that separates the dark panel from a dark host behind it.
    static let hairline = Color.white.opacity(0.12)

    /// Selection wash for the active row/cell. A soft white fill (the Spotlight/menu idiom) instead
    /// of a saturated accent bar, so the highlight guides the eye without shouting.
    static let selectionFill = Color.white.opacity(0.16)

    /// Primary and secondary text tuned for legibility on the charcoal backdrop.
    static let primaryText = Color.white.opacity(0.95)
    static let secondaryText = Color.white.opacity(0.5)
}

/// Applies the committed-dark HUD backdrop, hairline border, and clip shape, and pins the subtree to
/// the dark color scheme so `.primary`/`.secondary` and any nested chrome resolve to their light
/// variants on the dark surface without each call site re-specifying colors.
struct PopupHUDChrome: ViewModifier {
    var cornerRadius: CGFloat = PopupTheme.cornerRadius

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(PopupTheme.backgroundGradient)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(PopupTheme.hairline, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            // Outermost so the backdrop, border, and all descendant content share the forced scheme.
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    /// Wraps the view in the shared dark popup chrome. `cornerRadius` defaults to `PopupTheme`.
    func popupHUDChrome(cornerRadius: CGFloat = PopupTheme.cornerRadius) -> some View {
        modifier(PopupHUDChrome(cornerRadius: cornerRadius))
    }
}
