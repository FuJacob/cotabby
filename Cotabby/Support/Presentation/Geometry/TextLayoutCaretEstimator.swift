import AppKit
import Foundation

/// File overview:
/// Estimates caret geometry from a hidden TextKit layout of the text before the caret, anchored
/// to the field's frame. Used when the host's AX caret geometry is unusable (`.estimated`: only
/// `AXFrame` is available) or demonstrably wrong (a `.derived` rect that disagrees with the text
/// layout by a full line — Gmail-class editors whose child-run mapping drifts across blank lines).
///
/// The layout itself is generalized on purpose — no per-app metrics tables — but it is calibrated
/// with whatever the host actually reveals about its own rendering:
///   - `observedLineHeight` (the AX caret rect's height, a real rendered line box) replaces the
///     font's natural line height. Web hosts commonly render with CSS line-height well above the
///     font metrics, and that error compounds per line: six lines at two-thirds height put the
///     ghost two full lines too high.
///   - `observedCharWidth` (measured from child text-run frames) rescales the approximated font so
///     soft-wrap points match the host's. A too-narrow font wraps too late, losing whole lines.
///   - `observedContentEdges` (leftmost/topmost child-run edges) replace the guessed content
///     insets, since `AXFrame` includes padding that AX never reports directly.
///
/// Deliberately conservative: any condition under which the hidden layout could lie about the real
/// field (truncated context window, possibly-scrolled content, tab stops, unusable frame) rejects
/// the estimate and the caller keeps the existing fallback behavior. Runs at presentation time
/// only, never inside the focus-poll hot path, so it adds no per-keystroke AX or layout cost while
/// no suggestion is being shown.
@MainActor
enum TextLayoutCaretEstimator {
    /// Everything the estimator needs, captured as plain values so the helper stays pure and
    /// trivially testable. The caller (coordinator) owns deciding *when* estimation applies;
    /// this type only describes one attempt. `Equatable` powers the single-entry memo below.
    struct Input: Equatable {
        /// Text before the caret. Callers append any synthetic insertion the host has not
        /// published yet, so the layout reflects what is actually on screen.
        let precedingText: String
        /// The field's `AXFrame` in Cocoa (bottom-left-origin) global screen coordinates, as
        /// carried by `FocusedInputContext.inputFrameRect`.
        let fieldFrame: CGRect?
        /// AX-resolved host font, when the host exposes one. Nil falls back to the system font.
        let fieldStyle: ResolvedFieldStyle?
        let isRightToLeft: Bool
        /// True when `precedingText` filled the snapshot's bounded context window, meaning the
        /// captured prefix may not start at the document start. Wrap and Y math would then be
        /// computed against a mid-document offset, which is meaningless — the estimator rejects.
        let prefixMayBeTruncated: Bool
        /// Host-rendered line-box height, when a trustworthy one is available (e.g. a `.derived`
        /// caret rect measured from real child-run frames). Overrides font-metric line height.
        let observedLineHeight: CGFloat?
        /// Average rendered character width measured from child-run frames; rescales the
        /// approximated font so wrap points match the host.
        let observedCharWidth: CGFloat?
        /// Real content edges measured from child-run frames; replaces the guessed insets.
        let observedContentEdges: ObservedContentEdges?

        init(
            precedingText: String,
            fieldFrame: CGRect?,
            fieldStyle: ResolvedFieldStyle?,
            isRightToLeft: Bool,
            prefixMayBeTruncated: Bool,
            observedLineHeight: CGFloat? = nil,
            observedCharWidth: CGFloat? = nil,
            observedContentEdges: ObservedContentEdges? = nil
        ) {
            self.precedingText = precedingText
            self.fieldFrame = fieldFrame
            self.fieldStyle = fieldStyle
            self.isRightToLeft = isRightToLeft
            self.prefixMayBeTruncated = prefixMayBeTruncated
            self.observedLineHeight = observedLineHeight
            self.observedCharWidth = observedCharWidth
            self.observedContentEdges = observedContentEdges
        }
    }

    /// A caret estimate in global Cocoa screen coordinates, plus the layout facts diagnostics
    /// want. `caretRect` matches the AX resolvers' caret shape: 2pt wide, one line tall.
    struct Estimate: Equatable {
        let caretRect: CGRect
        /// Effective line unit of the layout: the observed line height when one was accepted,
        /// else the approximated font's natural line height.
        let lineHeight: CGFloat
        /// Zero-based visual line the caret landed on after soft wrapping.
        let lineIndex: Int
        /// Whether the field was treated as a multi-line editor (top-aligned content) or a
        /// single-line input (vertically centered content).
        let isMultiLineField: Bool
        /// Diagnostics: which host measurements actually calibrated this estimate, and the final
        /// (possibly width-rescaled) layout font size. Logged so a misplaced overlay in the field
        /// can be traced to a missing or rejected calibration.
        let usedObservedLineHeight: Bool
        let usedObservedContentEdges: Bool
        let layoutFontPointSize: CGFloat
    }

    /// Why an estimate was refused. Raw values feed the structured log stream so a misplaced
    /// overlay can be traced to the exact gate that fired.
    enum RejectionReason: String, Equatable {
        case prefixTruncated
        case fieldFrameUnusable
        case containsTab
        case verticalOverflow
        case horizontalOverflow
        case layoutFailed
    }

    enum Outcome: Equatable {
        case estimate(Estimate)
        case rejected(RejectionReason)
    }

    /// Generalized layout constants — fallbacks for hosts that reveal nothing measurable, plus
    /// sanity bounds for the measurements themselves. Errors in the fallbacks cost a few points
    /// of offset, which is far smaller than the line-level errors of an uncalibrated layout.
    private enum Metrics {
        /// Typical content inset between a field's border and its text, used when no content
        /// edges were observed. Native NSTextField uses 2-4pt; web inputs usually pad more, but
        /// overshooting pushes ghost text into the text run, so we stay near the native value.
        static let horizontalInset: CGFloat = 4
        /// Top content inset for multi-line editors, used when no content edges were observed.
        static let topInset: CGFloat = 4
        /// Below this width the "field" is more likely a mis-resolved AX node than a text input,
        /// and one wrap line would hold almost nothing — reject rather than guess.
        static let minimumFieldWidth: CGFloat = 40
        /// Matches the 2pt caret width the AX resolvers normalize to.
        static let caretWidth: CGFloat = 2
        /// Fields at least two line-units tall are treated as multi-line editors; anything
        /// shorter centers its single line vertically.
        static let multiLineHeightFactor: CGFloat = 2
        /// AX-reported font sizes are host-supplied and occasionally garbage; clamp to a sane
        /// text-field range before trusting them for layout.
        static let minimumFontPointSize: CGFloat = 8
        static let maximumFontPointSize: CGFloat = 72
        /// Observed line boxes outside this range are junk (e.g. a whole-field rect), not a line.
        static let minimumObservedLineHeight: CGFloat = 8
        static let maximumObservedLineHeight: CGFloat = 60
        /// Bounds on the width-calibration rescale so one noisy run measurement cannot drag the
        /// layout font to an absurd size.
        static let minimumObservedWidthScale: CGFloat = 0.65
        static let maximumObservedWidthScale: CGFloat = 1.6
        /// A measured left inset beyond this fraction of the field width is distrusted — it is
        /// more likely a heavily indented first run (quote, list) than real padding.
        static let maximumMeasuredLeftInsetFraction: CGFloat = 0.4
        /// A measured top inset beyond this fraction of the field height is distrusted.
        static let maximumMeasuredTopInsetFraction: CGFloat = 0.5
        /// Content narrower than this after insets cannot lay out meaningfully.
        static let minimumContentWidth: CGFloat = 24
        /// Plain English sample used to estimate a font's average character width; the observed
        /// average from host runs is compared against this to derive the rescale factor.
        static let widthSampleText = "the quick brown fox jumps over the lazy dog, The Quick 0123456789. "
    }

    /// Single-entry memo. Reconcile ticks re-present with byte-identical inputs several times per
    /// second while a ghost is visible, and the layout is a pure function of its input, so one
    /// cached outcome removes the TextKit recompute from the per-keystroke path. One entry is
    /// enough: consecutive presents only diverge when the text or field actually changed.
    private static var memo: (input: Input, outcome: Outcome)?

    /// One reusable hidden measurement stack, wired once. Safe to share because the estimator is
    /// main-actor confined and each estimate fully replaces the storage contents and container
    /// size before forcing layout.
    private struct MeasurementStack {
        let storage: NSTextStorage
        let layoutManager: NSLayoutManager
        let container: NSTextContainer
    }

    private static let sharedTextKit: MeasurementStack = {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: .zero)
        // Zero padding so container X equals content X; the field inset is applied once during
        // screen mapping instead.
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        return MeasurementStack(storage: storage, layoutManager: layoutManager, container: container)
    }()

    static func estimate(for input: Input) -> Outcome {
        if let memo, memo.input == input {
            return memo.outcome
        }
        let outcome = computeEstimate(for: input)
        memo = (input, outcome)
        return outcome
    }

    private static func computeEstimate(for input: Input) -> Outcome {
        if input.prefixMayBeTruncated {
            return .rejected(.prefixTruncated)
        }
        guard let rawFrame = input.fieldFrame, rectIsUsable(rawFrame) else {
            return .rejected(.fieldFrameUnusable)
        }
        // Tab rendering depends on host tab stops we cannot observe; one tab can shift every
        // following glyph by an arbitrary amount, so any tab in the prefix poisons the layout.
        if input.precedingText.contains("\t") {
            return .rejected(.containsTab)
        }

        let frame = rawFrame.standardized
        let font = approximatedFont(for: input.fieldStyle, observedCharWidth: input.observedCharWidth)
        let fontLineHeight = ceil(font.ascender - font.descender + font.leading)
        let observedLineHeight = sanitizedObservedLineHeight(
            input.observedLineHeight,
            fieldHeight: frame.height
        )
        // The effective line unit. A host-measured line box wins over font metrics because CSS
        // line-height routinely exceeds the font's natural height and the error compounds per line.
        let lineUnit = observedLineHeight ?? fontLineHeight

        let insets = contentInsets(
            from: input.observedContentEdges,
            frame: frame,
            precedingText: input.precedingText
        )
        let availableWidth = frame.width - insets.left - insets.right
        guard lineUnit > 0, availableWidth >= Metrics.minimumContentWidth else {
            return .rejected(.fieldFrameUnusable)
        }

        let isMultiLineField = frame.height >= Metrics.multiLineHeightFactor * lineUnit

        guard let local = localCaretPosition(
            text: input.precedingText,
            font: font,
            paragraphLineHeight: observedLineHeight,
            availableWidth: availableWidth,
            isRightToLeft: input.isRightToLeft
        ) else {
            return .rejected(.layoutFailed)
        }

        if isMultiLineField {
            // If the laid-out content is taller than the field, the field is (or could be)
            // scrolled and we cannot know the offset, so the caret's on-screen Y is unknowable.
            if insets.top + local.contentBottom > frame.height {
                return .rejected(.verticalOverflow)
            }
        } else if local.caretLineTop > 0.5 {
            // A single-line field never wraps for real; if our layout wrapped (or the prefix
            // contains a newline), the prefix is wider than the visible field and the host has
            // scrolled horizontally by an amount we cannot observe.
            return .rejected(.horizontalOverflow)
        }

        // Trailing whitespace at a soft-wrap boundary "hangs" past the container edge instead of
        // wrapping; clamp it back to the content box rather than rejecting — the suggestion after
        // "word " is the single most common trigger position.
        let clampedX = min(max(local.caretX, 0), availableWidth)
        let caretHeight = min(local.caretHeight, frame.height)
        let screenX = frame.minX + insets.left + clampedX
        let screenY: CGFloat
        if isMultiLineField {
            // Container coordinates grow downward from the content's top edge; Cocoa Y grows
            // upward. The caret rect's origin is its bottom edge.
            screenY = frame.maxY - insets.top - local.caretLineTop - caretHeight
        } else {
            screenY = frame.midY - caretHeight / 2
        }

        let estimate = Estimate(
            caretRect: CGRect(x: screenX, y: screenY, width: Metrics.caretWidth, height: caretHeight),
            lineHeight: lineUnit,
            lineIndex: local.lineIndex,
            isMultiLineField: isMultiLineField,
            usedObservedLineHeight: observedLineHeight != nil,
            usedObservedContentEdges: insets.isMeasured,
            layoutFontPointSize: font.pointSize
        )
        return .estimate(estimate)
    }

    // MARK: - Calibration

    /// Resolves the layout font from the AX-probed field style, falling back stepwise: host face
    /// at host size, system face at host size (face missing or not installed), then system face
    /// at system size. When the host's average character width was measured from real run frames,
    /// the font is rescaled so its average width matches — wrap fidelity depends on width, and a
    /// face that measures narrower than the host's wraps too late and loses whole lines.
    private static func approximatedFont(
        for style: ResolvedFieldStyle?,
        observedCharWidth: CGFloat?
    ) -> NSFont {
        let base = baseFont(for: style)
        guard let observedCharWidth, observedCharWidth > 0 else {
            return base
        }
        let sampleAverage = averageCharWidth(of: base)
        guard sampleAverage > 0 else {
            return base
        }
        let scale = min(
            max(observedCharWidth / sampleAverage, Metrics.minimumObservedWidthScale),
            Metrics.maximumObservedWidthScale
        )
        guard abs(scale - 1) > 0.02 else {
            return base
        }
        let scaledSize = min(
            max(base.pointSize * scale, Metrics.minimumFontPointSize),
            Metrics.maximumFontPointSize
        )
        return NSFont(descriptor: base.fontDescriptor, size: scaledSize) ?? base
    }

    private static func baseFont(for style: ResolvedFieldStyle?) -> NSFont {
        let clampedSize = (style?.fontPointSize).map {
            min(max($0, Metrics.minimumFontPointSize), Metrics.maximumFontPointSize)
        }
        let size = clampedSize ?? NSFont.systemFontSize
        if let name = style?.fontName, let font = NSFont(name: name, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size)
    }

    /// Average character width of a generic English sample in the given font. The host-observed
    /// average (from real run frames) divided by this gives the width-calibration scale.
    private static func averageCharWidth(of font: NSFont) -> CGFloat {
        let sample = Metrics.widthSampleText as NSString
        guard sample.length > 0 else {
            return 0
        }
        return sample.size(withAttributes: [.font: font]).width / CGFloat(sample.length)
    }

    /// Accepts an observed line box only when it is line-sized: whole-field rects (the `.estimated`
    /// AXFrame fallback) and other junk heights would otherwise poison every per-line computation.
    private static func sanitizedObservedLineHeight(
        _ height: CGFloat?,
        fieldHeight: CGFloat
    ) -> CGFloat? {
        guard let height,
            height >= Metrics.minimumObservedLineHeight,
            height <= Metrics.maximumObservedLineHeight,
            height <= fieldHeight else {
            return nil
        }
        return height
    }

    private struct ContentInsets {
        let left: CGFloat
        let right: CGFloat
        let top: CGFloat
        /// True when at least one inset came from a real measurement rather than the defaults.
        let isMeasured: Bool
    }

    /// Derives content insets from measured run edges, with sanity gates per axis; any distrusted
    /// measurement falls back to the generalized default for that axis.
    ///
    /// The top edge is only trusted when the prefix does not start with a line break: the topmost
    /// run is the first *rendered* text, so leading blank lines would sit above it and the
    /// anchor would be one line too high per blank.
    private static func contentInsets(
        from edges: ObservedContentEdges?,
        frame: CGRect,
        precedingText: String
    ) -> ContentInsets {
        var left = Metrics.horizontalInset
        var top = Metrics.topInset
        var isMeasured = false

        if let edges {
            let measuredLeft = edges.leftX - frame.minX
            if measuredLeft >= 0,
                measuredLeft <= frame.width * Metrics.maximumMeasuredLeftInsetFraction,
                frame.width - 2 * measuredLeft >= Metrics.minimumContentWidth {
                left = measuredLeft
                isMeasured = true
            }

            let measuredTop = frame.maxY - edges.topY
            let prefixStartsWithLineBreak = precedingText.first.map(\.isNewline) ?? false
            if !prefixStartsWithLineBreak,
                measuredTop >= 0,
                measuredTop <= frame.height * Metrics.maximumMeasuredTopInsetFraction {
                top = measuredTop
                isMeasured = true
            }
        }

        // Horizontal padding is assumed symmetric; AX reveals only where content starts, not where
        // the host would wrap, and symmetric padding is the overwhelmingly common case.
        return ContentInsets(left: left, right: left, top: top, isMeasured: isMeasured)
    }

    // MARK: - Hidden layout

    /// Caret position in container-local coordinates (top-left origin, Y grows downward), plus
    /// the laid-out content's bottom edge for the scroll-ambiguity gate.
    private struct LocalCaretPosition {
        let caretX: CGFloat
        let caretLineTop: CGFloat
        let caretHeight: CGFloat
        let lineIndex: Int
        let contentBottom: CGFloat
    }

    /// Lays out `text` exactly once in a detached TextKit stack (never attached to a view or
    /// window — we only need geometry, not pixels) and reads the insertion point after the last
    /// character. TextKit owns wrap decisions, glyph advances, and bidi ordering, which is the
    /// fidelity a proportional width guess could never reach.
    private static func localCaretPosition(
        text: String,
        font: NSFont,
        paragraphLineHeight: CGFloat?,
        availableWidth: CGFloat,
        isRightToLeft: Bool
    ) -> LocalCaretPosition? {
        // The effective line unit: the pinned line box when one was measured, else the font's
        // natural height. Matches `estimate(for:)`'s `lineUnit` by construction.
        let fallbackLineHeight = paragraphLineHeight
            ?? ceil(font.ascender - font.descender + font.leading)
        // Empty fields are a common repair target (focus lands, AX exposes nothing useful yet);
        // the insertion point is simply the content origin.
        guard !text.isEmpty else {
            return LocalCaretPosition(
                caretX: isRightToLeft ? availableWidth : 0,
                caretLineTop: 0,
                caretHeight: fallbackLineHeight,
                lineIndex: 0,
                contentBottom: fallbackLineHeight
            )
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        // `.natural` alignment follows the writing direction, so RTL fragments right-align inside
        // the container and the computed X stays container-left-relative for both directions.
        paragraphStyle.baseWritingDirection = isRightToLeft ? .rightToLeft : .leftToRight
        // Pin every line to the host-measured line box when one was accepted; per-line error
        // against the real renderer otherwise compounds into whole-line drift.
        if let paragraphLineHeight {
            paragraphStyle.minimumLineHeight = paragraphLineHeight
            paragraphStyle.maximumLineHeight = paragraphLineHeight
        }

        // The memo above only hits on byte-identical re-presents; every keystroke while a ghost
        // is visible misses it, so allocating a fresh storage/layout-manager/container trio per
        // miss was per-keystroke churn. Mutating the shared stack invalidates its layout, so each
        // call still computes from clean state.
        let storage = Self.sharedTextKit.storage
        let layoutManager = Self.sharedTextKit.layoutManager
        let container = Self.sharedTextKit.container
        storage.setAttributedString(
            NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraphStyle])
        )
        container.size = CGSize(width: availableWidth, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)

        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0 else {
            return nil
        }

        var fragmentTops: [CGFloat] = []
        layoutManager.enumerateLineFragments(
            forGlyphRange: NSRange(location: 0, length: glyphCount)
        ) { rect, _, _, _, _ in
            fragmentTops.append(rect.minY)
        }

        var contentBottom = layoutManager.usedRect(for: container).maxY

        // A trailing line break puts the insertion point on the "extra" line fragment below the
        // last glyph — TextKit models that empty final line explicitly. `\n` also covers `\r\n`;
        // bare `\r` and the Unicode separators are checked for completeness.
        if text.hasSuffix("\n") || text.hasSuffix("\r")
            || text.hasSuffix("\u{2028}") || text.hasSuffix("\u{2029}") {
            let extra = layoutManager.extraLineFragmentRect
            let caretLineTop = extra.isEmpty ? contentBottom : extra.minY
            // The extra fragment is laid out without the text's paragraph style, so pin its height
            // to the effective line unit rather than trusting the unstyled default.
            let caretHeight = paragraphLineHeight
                ?? (extra.isEmpty ? fallbackLineHeight : max(extra.height, 1))
            contentBottom = max(contentBottom, caretLineTop + caretHeight)
            return LocalCaretPosition(
                caretX: isRightToLeft ? availableWidth : 0,
                caretLineTop: caretLineTop,
                caretHeight: caretHeight,
                lineIndex: fragmentTops.count,
                contentBottom: contentBottom
            )
        }

        let lastGlyph = glyphCount - 1
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: lastGlyph, length: 1),
            in: container
        )
        // The insertion point sits at the trailing edge of the final glyph: maxX when the text
        // advances rightward, minX when it advances leftward.
        let caretX = isRightToLeft ? glyphRect.minX : glyphRect.maxX
        let lineIndex = fragmentTops.lastIndex { $0 <= lineRect.minY + 0.5 } ?? 0
        contentBottom = max(contentBottom, lineRect.maxY)
        return LocalCaretPosition(
            caretX: caretX,
            caretLineTop: lineRect.minY,
            caretHeight: max(lineRect.height, 1),
            lineIndex: lineIndex,
            contentBottom: contentBottom
        )
    }

    private static func rectIsUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && !rect.isEmpty
            && rect.standardized.width >= Metrics.minimumFieldWidth
    }
}
