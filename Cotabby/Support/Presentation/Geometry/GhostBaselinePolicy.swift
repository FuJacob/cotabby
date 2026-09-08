import AppKit
import Foundation

/// File overview:
/// The one rule that decides how far below the top of the host's caret box the ghost text's
/// baseline sits. Getting this wrong by a point is the "ghost text is a few pixels low" report;
/// getting it right is what makes ghost glyphs sit on the host's own baseline.
///
/// Two renderer families place text differently inside a line box, and both were measured against
/// live hosts before this policy was written:
///
/// - **TextKit** (AppKit `NSTextView`/`NSTextField`: TextEdit, Notes, Mail, Antinote, ...). The AX
///   caret box is the layout manager's line fragment (`defaultLineHeight`, e.g. 16pt for Menlo 14,
///   14pt for Helvetica 12), and the baseline sits at `defaultBaselineOffset` from its top (13pt and
///   11pt respectively). That offset is *not* the glyph box centered in the fragment: for Helvetica
///   12 the centered guess lands 0.76pt too high. TextKit's own rounding rules are therefore asked
///   directly through `NSLayoutManager` instead of being re-derived.
/// - **Web engines** (Chromium/Blink, WebKit: Chrome, Safari, Electron apps). Blink rounds the font's
///   ascent and descent to whole pixels and stacks them into a content area. The AX box for a
///   caret or character is usually exactly that content area (Georgia 18px reports 21 = 17 + 4,
///   Menlo 13px reports 15 = 12 + 3, the system font at 15px reports 17 = 14 + 3), so the baseline
///   is the rounded ascent from the top. Single-line `<input>` controls report their taller inner
///   box instead; there the content area is centered, so the same rounded ascent applies after
///   splitting the leftover height evenly.
///
/// Kept pure (font metrics in, one number out) so both rules are unit-tested against the values
/// measured from real hosts.
enum GhostBaselinePolicy {
    /// Which text engine produced the caret box. Chosen from `isWebContentField`, which the focus
    /// resolver derives from DOM-reflection attributes and browser/Electron bundle identity.
    enum HostRenderer: Equatable {
        case textKit
        case webEngine
    }

    /// Distance from the top edge of the host's caret/line box to the text baseline, in points.
    static func baselineOffsetFromTop(font: NSFont, boxHeight: CGFloat, renderer: HostRenderer) -> CGFloat {
        switch renderer {
        case .textKit:
            return textKitBaselineOffset(font: font, boxHeight: boxHeight)
        case .webEngine:
            return webEngineBaselineOffset(font: font, boxHeight: boxHeight)
        }
    }

    /// TextKit line fragment: baseline at the layout manager's default offset. When the host's box
    /// is taller than the default fragment (a paragraph style raised the minimum line height), the
    /// extra space sits above the glyphs in TextKit 1, so the descent portion below the baseline is
    /// held constant and the baseline moves down with the box.
    private static func textKitBaselineOffset(font: NSFont, boxHeight: CGFloat) -> CGFloat {
        let layoutManager = NSLayoutManager()
        let defaultHeight = layoutManager.defaultLineHeight(for: font)
        let defaultBaseline = layoutManager.defaultBaselineOffset(for: font)
        guard boxHeight > 0, abs(boxHeight - defaultHeight) > 1 else {
            return defaultBaseline
        }
        let descentPortion = defaultHeight - defaultBaseline
        return max(defaultBaseline, boxHeight - descentPortion)
    }

    /// Blink/WebKit content area: rounded ascent stacked on rounded descent. The exact rounding of
    /// each metric is recovered from the measured box height whenever the two candidate roundings
    /// can reproduce it (this is what makes the 15px system font come out as 14 + 3 = 17 even
    /// though its ascent of 14.502 would naively round to 15); otherwise the box is a line box and
    /// the content area is centered inside it.
    ///
    /// Both engines also carry Safari's old "match the Microsoft metrics" adjustment: for the
    /// platform families Times, Helvetica and Courier, 15% of the rounded content height is added
    /// to the ascent (measured live: Chrome's `<input>` in Helvetica 16px reports an 18pt box,
    /// which is 12 + floor(16 · 0.15) = 14 of ascent over 4 of descent, and its text sits on the
    /// 14pt baseline). Without it the box reads as a centered 16pt content area, a full point high.
    private static func webEngineBaselineOffset(font: NSFont, boxHeight: CGFloat) -> CGFloat {
        let ascent = font.ascender
        let descent = -font.descender
        let hack = legacyAscentAdjustment(for: font, roundedAscent: ascent.rounded(), roundedDescent: descent.rounded())
        let roundedBox = boxHeight.rounded()
        let ascentCandidates = [ascent.rounded(), floor(ascent), ceil(ascent)]
        let descentCandidates = [descent.rounded(), floor(descent), ceil(descent)]
        for ascentCandidate in ascentCandidates {
            for descentCandidate in descentCandidates where ascentCandidate + hack + descentCandidate == roundedBox {
                return ascentCandidate + hack
            }
        }
        let contentHeight = ascent.rounded() + hack + descent.rounded()
        return (boxHeight - contentHeight) / 2 + ascent.rounded() + hack
    }

    /// Families Blink and WebKit stretch to match their Windows counterparts (`SimpleFontData`
    /// platform init on macOS). Exact family names only: "Helvetica Neue" and "Times New Roman"
    /// are left alone by the engines too.
    static let legacyAdjustedFamilies: Set<String> = ["Times", "Helvetica", "Courier"]

    private static func legacyAscentAdjustment(for font: NSFont, roundedAscent: CGFloat, roundedDescent: CGFloat) -> CGFloat {
        guard let family = font.familyName, legacyAdjustedFamilies.contains(family) else { return 0 }
        return floor((roundedAscent + roundedDescent) * 15 / 100)
    }
}
