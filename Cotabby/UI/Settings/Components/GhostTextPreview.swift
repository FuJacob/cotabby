import SwiftUI

/// File overview:
/// A non-interactive sample that shows how an inline suggestion will look with the user's chosen
/// ghost-text color, opacity, and size. It is deliberately fake — there is no text field or model
/// behind it — so a user can judge their Appearance choices at a glance without switching to another
/// app and triggering a real suggestion.
///
/// Fidelity: the typed prefix renders in the primary label color (like text the user already typed)
/// and the trailing run renders in the resolved ghost color at the chosen opacity (like a live
/// suggestion), matching how `GhostSuggestionView` splits already-typed text from the ghost. The two
/// runs are concatenated into one `Text` so the sample wraps as a single paragraph when a large size
/// multiplier makes it outgrow the row, instead of clipping the ghost half.
///
/// Size: the real overlay derives its point size from the caret height, which does not exist here, so
/// a fixed mid-band base stands in for it and is scaled by the same multiplier the overlay applies.
/// The preview therefore communicates the *relative* effect of the size control, which is the choice
/// the user is actually making.
struct GhostTextPreview: View {
    /// The resolved base ghost color, WITHOUT opacity applied — the view fades the ghost run itself so
    /// the typed prefix stays at full strength, exactly like the overlay.
    let ghostColor: Color
    /// Ghost-run fade in `[0.3, 1.0]`, applied only to the suggestion half.
    let opacity: Double
    /// Final preview point size (the representative base already scaled by the user's multiplier).
    let fontSize: CGFloat

    /// Representative base size the multiplier scales in the preview. Sits near the lower end of
    /// the overlay's real `[14, 24]` caret-derived band, matching typical small-to-medium text
    /// fields where most users encounter ghost text in practice.
    static let baseFontSize: CGFloat = 16

    /// The whole sentence reads naturally with the ghost half completing the typed half, and labels
    /// itself as a sample so the user understands this is a preview rather than a real input.
    private let typedText = "This is how your "
    private let ghostText = "suggestions will look"

    var body: some View {
        let sample = Text(typedText).foregroundStyle(.primary)
            + Text(ghostText).foregroundStyle(ghostColor.opacity(opacity))

        return sample
            .font(.system(size: fontSize))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            // One decorative element: the configured values are what the user reads off the controls,
            // so the sample text itself carries no extra information for VoiceOver.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preview of how suggestions will appear")
    }
}
