import AppKit
import SwiftUI

/// SwiftUI content hosted by `OverlayController`'s non-activating AppKit panel.
/// Keeping styling here lets the controller focus on window lifetime, positioning, and state publication.

/// The green used to signal a typo correction. Tuned per color scheme so it stays legible in both
/// appearances without dropping below a comfortable contrast floor against typical text-field
/// backgrounds. Shared by the inline ghost and the mirror card so a correction reads identically in
/// either display mode; the user's custom suggestion color is intentionally bypassed for corrections
/// because semantic communication beats personalization here.
enum SuggestionCorrectionStyle {
    static func color(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.45, green: 0.85, blue: 0.45)
            : Color(red: 0.15, green: 0.60, blue: 0.20)
    }
}

/// Visual hint that teaches the user which key accepts the suggestion. The label tracks the user's
/// configured accept keybind, so rebinding away from Tab updates the pill instead of lying about it.
struct GhostKeycap: View {
    @Environment(\.colorScheme) var colorScheme
    let label: String

    var textColor: Color {
        colorScheme == .dark ? Color(white: 0.65) : Color(white: 0.45)
    }

    var bgColor: Color {
        colorScheme == .dark ? Color(white: 0.18) : Color(white: 0.95)
    }

    var borderColor: Color {
        colorScheme == .dark ? Color(white: 0.3) : Color(white: 0.8)
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(textColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(bgColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .fixedSize(horizontal: true, vertical: true)
    }
}

/// Mirror-mode card. Renders the suggestion inside a Cotabby-owned backdrop anchored below the
/// focused field. Unlike `GhostSuggestionView`, this view is single-line by design — the whole
/// reason mirror mode exists is that the host's caret rect is unreliable, so multi-line wrapping
/// would just compound the positioning uncertainty.
///
/// The backdrop and shadow are what make this read as a deliberate UI element instead of a stray
/// floating text label. We do not try to disguise the card as the host editor; Cotypist's product
/// language ("preview") is the right framing here.
struct MirrorOverlayView: View {
    let layout: MirrorOverlayLayout
    let customColor: Color?
    let keycapLabel: String?
    let opacity: Double
    /// When true, the suggestion replaces a typo'd word; the whole card lights up green to match the
    /// inline ghost, and the next-accept-word highlight is suppressed (the correction is one unit).
    let isCorrection: Bool

    /// The card is now a committed-dark HUD in every host appearance, so the suggestion text is
    /// always the light-on-dark value rather than branching on the system scheme (which would bake
    /// dark-gray text onto the dark card over a light host). The correction green likewise uses the
    /// dark-appropriate tone.
    private var ghostColor: Color {
        if isCorrection {
            return SuggestionCorrectionStyle.color(for: .dark).opacity(opacity)
        }
        let baseColor = customColor ?? Color(red: 0.85, green: 0.85, blue: 0.85)
        return baseColor.opacity(opacity)
    }

    /// The next-accept word renders at full strength so it reads as "this is what Tab takes next."
    /// The user's custom suggestion color (if set) is honored at full opacity; otherwise the primary
    /// label color keeps strong contrast against the card backdrop in both appearances.
    private var highlightColor: Color {
        customColor ?? .primary
    }

    /// The suggestion as one attributed run: the highlighted prefix (the next accept-word) is drawn
    /// full-strength and semibold so it "lights up" as the word being completed, while the rest keeps
    /// the muted ghost color. Building one `AttributedString` instead of two `Text`s keeps the card on
    /// a single line and lets tail-truncation treat the whole suggestion as one unit.
    private var styledSuggestion: AttributedString {
        var attributed = AttributedString(layout.suggestionText)
        attributed.font = .system(size: layout.fontSize)
        attributed.foregroundColor = ghostColor

        // A correction replaces the whole word, so the entire run stays green; the next-accept-word
        // highlight (which marks where Tab stops mid-completion) does not apply to a correction.
        guard !isCorrection else { return attributed }

        let prefix = layout.highlightedPrefix
        guard !prefix.isEmpty, layout.suggestionText.hasPrefix(prefix) else {
            return attributed
        }
        let characters = attributed.characters
        let highlightEnd = characters.index(characters.startIndex, offsetBy: prefix.count)
        let highlightRange = characters.startIndex..<highlightEnd
        attributed[highlightRange].foregroundColor = highlightColor
        attributed[highlightRange].font = .system(size: layout.fontSize, weight: .semibold)
        return attributed
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(styledSuggestion)
                .lineLimit(1)
                .truncationMode(.tail)

            if let keycapLabel {
                GhostKeycap(label: keycapLabel)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        // The panel itself is sized by MirrorOverlayLayout to the card dimensions, so the content
        // fills the panel exactly and the shared chrome paints the committed-dark backdrop. The
        // forced-dark scheme inside `popupHUDChrome` is what flips `styledSuggestion` and the keycap
        // to their light variants, so the popup reads the same dark over a white host as a dark one.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .popupHUDChrome()
        // Right-to-left hosts get the SwiftUI environment flip so the keycap lands on the leading
        // side of the suggestion text, mirroring how RTL languages read.
        .environment(\.layoutDirection, layout.isRightToLeft ? .rightToLeft : .leftToRight)
    }
}
