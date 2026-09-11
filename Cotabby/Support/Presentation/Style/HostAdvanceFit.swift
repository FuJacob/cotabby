import AppKit

/// File overview:
/// The host's text size, read from where its own caret lands as the user types along a line.
///
/// Why this exists: a host that reports no font size is sized from a pixel match of a short strip,
/// and that strip's size search is coarse until the strip holds enough text for its advance fit. A
/// match that scores well is settled and never measured again. Claude's Code composer is the
/// measured case (2026-09-11): the match settled on Anthropic Sans at 15.1585 from thirteen
/// characters, where the host paints its 14px at the app's 1.0954 zoom, 15.336, and every ghost ran
/// short by a point and a half over a line, for the field's life.
///
/// Every caret the pixels measure on a paragraph's first line lies on one straight line:
/// `caretX = lineStart + scale × advance(text before the caret)`, with the advance taken in the
/// ghost's face. The slope is the host's size over the face's; that session's 23 captures across
/// 500pt gave 15.339. The slope is Theil–Sen's (the median of the pairwise slopes), because a
/// capture can read the host a glyph early or late: five of those 23 were 3pt off, and a
/// least-squares line through them put the line's start half a point wrong.
///
/// Adoption follows `TypefaceEvidence`'s rule against a size that follows every new capture: the
/// first fit spanning `minimumSpan` is adopted, and only a fit spanning `refinementFactor` times as
/// much replaces it, at most `maximumRefinements` times, so the ghost is resized a few times per
/// field and each time by less.
///
/// A value type owned per field by `OverlayController`; the captures come from `PixelCaretLocator`.
nonisolated struct HostAdvanceFit: Equatable {
    /// One capture: the paragraph's text before the caret and where the caret was measured.
    struct Capture: Equatable {
        let text: String
        let caretX: CGFloat
    }

    struct Fit: Equatable {
        /// The host's size for the face the fit was taken in.
        let pointSize: CGFloat
        /// Points of host advance between the fit's leftmost and rightmost capture.
        let span: CGFloat
        let captures: Int
    }

    static let minimumCaptures = 5
    /// Host advance a fit must span before it is adopted: a capture's caret is good to about a
    /// quarter point, so 150pt holds the scale to a few tenths of a percent.
    static let minimumSpan: CGFloat = 150
    /// Two captures closer than this give no slope worth taking.
    static let minimumPairAdvance: CGFloat = 24
    static let maximumCaptures = 40
    static let refinementFactor: CGFloat = 2
    static let maximumRefinements = 2
    /// A fit further than this from the face's own size is not this face's line (another line's
    /// captures, a wrong face) and is refused.
    static let maximumDeviation: CGFloat = 0.06

    private(set) var faceName: String?
    private(set) var lineKey: String?
    private(set) var captures: [Capture] = []
    private(set) var adopted: Fit?
    private(set) var refinements = 0

    /// Records a capture of the caret on the first line of a paragraph (`lineKey` names that line:
    /// the captures of one line share its start) and returns the fit when this capture adopted or
    /// refined it. `face` is the ghost's face at the host size it currently assumes; a new face
    /// starts the field over, a new line starts its captures over.
    mutating func record(text: String, caretX: CGFloat, lineKey: String, face: NSFont) -> Fit? {
        if face.fontName != faceName {
            faceName = face.fontName
            adopted = nil
            refinements = 0
            captures = []
        }
        if lineKey != self.lineKey {
            self.lineKey = lineKey
            captures = []
        }
        captures.append(Capture(text: text, caretX: caretX))
        if captures.count > Self.maximumCaptures {
            captures.removeFirst()
        }
        guard let fit = Self.fit(captures, face: face), abs(fit.pointSize / face.pointSize - 1) <= Self.maximumDeviation else {
            return nil
        }
        if let adopted {
            guard refinements < Self.maximumRefinements, fit.span >= adopted.span * Self.refinementFactor else { return nil }
            refinements += 1
        }
        adopted = fit
        return fit
    }

    /// The host's size from `captures` of one line, advances measured in `face`: the Theil–Sen slope
    /// of caret against advance, times the face's size. Nil with too few captures or too little span.
    static func fit(_ captures: [Capture], face: NSFont) -> Fit? {
        guard captures.count >= minimumCaptures, face.pointSize > 0 else { return nil }
        let advances = captures.map { GhostFontResolver.width(of: $0.text, font: face) }
        var slopes: [CGFloat] = []
        for first in captures.indices {
            for second in captures.indices where second > first {
                let run = advances[second] - advances[first]
                guard abs(run) >= minimumPairAdvance else { continue }
                slopes.append((captures[second].caretX - captures[first].caretX) / run)
            }
        }
        guard slopes.count >= minimumCaptures, let low = advances.min(), let high = advances.max() else { return nil }
        slopes.sort()
        let slope = slopes[slopes.count / 2]
        let span = (high - low) * slope
        guard slope > 0, span >= minimumSpan else { return nil }
        return Fit(pointSize: face.pointSize * slope, span: span, captures: captures.count)
    }
}
