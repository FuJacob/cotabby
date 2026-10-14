import SwiftUI

/// File overview:
/// The small Cotabby affordance shown just outside a supported text field: the built-in cat glyph
/// on Cotabby's dark rounded chip, or a wand while it is the selection-rewrite button.
struct FieldEdgeIconIndicatorView: View {
    // Sized at 0.7 of the original chip so the affordance sits more discreetly beside the input.
    private let side: CGFloat = 14
    private let cornerRadius: CGFloat = 3.5
    /// Text is selected and can be rewritten: the icon becomes the rewrite button (a wand), so the
    /// affordance stays at the field's edge instead of a second button covering the selection.
    var rewrite = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(red: 0.18, green: 0.19, blue: 0.21))
            if rewrite {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Image("MenuBarCatIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 9.1)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .fixedSize()
    }
}
