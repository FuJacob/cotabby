import AppKit
import SwiftUI

/// File overview:
/// The small Cotabby affordance shown just outside a supported text field. The same view backs both
/// the live activation indicator and the Settings preview, so what the user configures is exactly
/// what they see near the caret.
///
/// With no `customImage` it renders the built-in cat glyph on Cotabby's dark rounded chip. With a
/// custom image it fills the chip edge-to-edge. Either way the result is clipped to the same rounded
/// rectangle, so user-supplied art receives the indicator's rounding.
struct FieldEdgeIconIndicatorView: View {
    /// Processed, roughly square icon. `nil` falls back to the built-in Cotabby cat.
    var customImage: NSImage?

    private let side: CGFloat = 20
    private let cornerRadius: CGFloat = 5

    var body: some View {
        ZStack {
            if let customImage {
                Image(nsImage: customImage)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(red: 0.18, green: 0.19, blue: 0.21))
                Image("MenuBarCatIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 13)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .fixedSize()
    }
}
