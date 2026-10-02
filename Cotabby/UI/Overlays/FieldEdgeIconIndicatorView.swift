import SwiftUI

/// File overview:
/// The small Cotabby affordance shown just outside a supported text field. Always renders the
/// built-in cat glyph on Cotabby's dark rounded chip.
struct FieldEdgeIconIndicatorView: View {
    // Sized at 0.7 of the original chip so the affordance sits more discreetly beside the input.
    private let side: CGFloat = 14
    private let cornerRadius: CGFloat = 3.5
    /// Autocomplete is off in this app or window. The icon stays (it is how the user turns it back
    /// on) but fades so it reads as "Cotabby is here, but paused".
    var dimmed = false

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
        .opacity(dimmed ? 0.45 : 1)
        .fixedSize()
    }
}
