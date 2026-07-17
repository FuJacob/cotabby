import SwiftUI

/// File overview:
/// The small Cotabby affordance shown just outside a supported text field. Always renders the
/// built-in cat glyph on Cotabby's dark rounded chip.
struct FieldEdgeIconIndicatorView: View {
    // Sized at 0.7 of the original chip so the affordance sits more discreetly beside the input.
    private let side: CGFloat = 14
    private let cornerRadius: CGFloat = 3.5

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(red: 0.18, green: 0.19, blue: 0.21))
            Image("MenuBarCatIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 9.1)
                .foregroundStyle(.white)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .fixedSize()
    }
}
