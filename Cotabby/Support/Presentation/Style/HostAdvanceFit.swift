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
/// A value type owned per field by `HostTypefaceResolver`; the captures come from `PixelCaretLocator`.
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
    /// The span a single-line field's fit is adopted at. Its text is often shorter than a paragraph
    /// line ever gets: Chrome's address bar held queries of 65 to 234pt while its caret-derived ghost
    /// ran 7% large (15.5 where each query's captures fitted 14.48 to 14.58, 2026-09-11). 60pt holds
    /// the scale to under half a percent, a tenth of that error.
    static let singleLineMinimumSpan: CGFloat = 60
    /// Two captures closer than this give no slope worth taking.
    static let minimumPairAdvance: CGFloat = 24
    static let maximumCaptures = 40
    static let refinementFactor: CGFloat = 2
    static let maximumRefinements = 2
    /// A fit further than this from the face's own size is not this face's line (another line's
    /// captures, a wrong face) and is refused.
    static let maximumDeviation: CGFloat = 0.06
    /// How far below the assumed size a fit may land when that size was only guessed from the
    /// caret's line box. The guess takes the box for a line height near 1.17; a host that sets a
    /// taller one paints smaller text in the same box, 1.375 in Discord's composer (16% smaller)
    /// and up to about 1.65 before this bound refuses it. Only downward: a line box bounds its
    /// text from above, so a fit above the guess is a wider family (a monospace host measured in
    /// the proportional stand-in), not larger text.
    static let caretBoxGuessMaximumShrink: CGFloat = 0.30

    /// Which fit sizes the field: none until one spans `minimumSpan`, then that one, replaced at
    /// most `maximumRefinements` times, each time by a fit spanning `refinementFactor` times as much.
    private nonisolated enum Adoption: Equatable {
        case none
        case adopted(Fit, refinements: Int)
    }

    private(set) var faceName: String?
    private(set) var lineKey: String?
    private(set) var captures: [Capture] = []
    private var adoption = Adoption.none

    /// The fit the field's ghost is sized from, once one has spanned enough.
    var adopted: Fit? {
        if case .adopted(let fit, _) = adoption { return fit }
        return nil
    }

    /// How many times the adopted fit has been replaced by a longer one.
    var refinements: Int {
        if case .adopted(_, let replaced) = adoption { return replaced }
        return 0
    }

    /// Records a capture of the caret on the first line of a paragraph (`lineKey` names that line:
    /// the captures of one line share its start) and returns the fit when this capture adopted or
    /// refined it. `face` is the ghost's face at the host size it currently assumes; a new face
    /// starts the field over, a new line starts its captures over. `minimumSpan` is `minimumSpan`
    /// for a paragraph's line and `singleLineMinimumSpan` for a single-line field. `maximumShrink`
    /// is how far below `face`'s size the fit may land: `maximumDeviation` for a size the host or
    /// an earlier fit gave, `caretBoxGuessMaximumShrink` for one guessed from the caret's box.
    mutating func record(
        text: String,
        caretX: CGFloat,
        lineKey: String,
        face: NSFont,
        minimumSpan: CGFloat = HostAdvanceFit.minimumSpan,
        maximumShrink: CGFloat = HostAdvanceFit.maximumDeviation
    ) -> Fit? {
        if face.fontName != faceName {
            faceName = face.fontName
            adoption = .none
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
        guard let fit = Self.fit(captures, face: face, minimumSpan: minimumSpan),
              Self.accepts(fittedSize: fit.pointSize, assumedSize: face.pointSize, maximumShrink: maximumShrink) else {
            return nil
        }
        switch adoption {
        case .none:
            adoption = .adopted(fit, refinements: 0)
        case .adopted(let previous, let replaced):
            guard replaced < Self.maximumRefinements, fit.span >= previous.span * Self.refinementFactor else { return nil }
            adoption = .adopted(fit, refinements: replaced + 1)
        }
        return fit
    }

    /// Whether a fit is this face's line at all: within `maximumDeviation` above the assumed size
    /// and `maximumShrink` below it.
    static func accepts(fittedSize: CGFloat, assumedSize: CGFloat, maximumShrink: CGFloat) -> Bool {
        guard assumedSize > 0 else { return false }
        let deviation = fittedSize / assumedSize - 1
        return deviation <= maximumDeviation && deviation >= -max(maximumShrink, maximumDeviation)
    }

    /// The host's size from `captures` of one line, advances measured in `face`: the Theil–Sen slope
    /// of caret against advance, times the face's size. Nil with too few captures or less span than
    /// `minimumSpan`.
    static func fit(_ captures: [Capture], face: NSFont, minimumSpan: CGFloat = HostAdvanceFit.minimumSpan) -> Fit? {
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
