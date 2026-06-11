import AppKit
import Foundation

/// File overview:
/// Estimates caret geometry for fields whose AX tree is too shallow to report a real caret rect.
/// When the geometry resolver lands on its last-resort branch (`.estimated`: only `AXFrame` is
/// available), the proportional text-length guess it ships drifts as the user types and gives up
/// on Y entirely, so those hosts degrade to the popup card. This helper instead lays out the text
/// before the caret in a hidden TextKit stack constrained to the field's width — the same
/// soft-wrap rules a real text view applies — and reads the insertion point off that layout,
/// anchored to the field's frame. A passing estimate is trustworthy enough for inline ghost text.
///
/// Deliberately conservative: any condition under which the hidden layout could lie about the real
/// field (truncated context window, possibly-scrolled content, tab stops, unusable frame) rejects
/// the estimate and the caller keeps today's fallback behavior. Fonts are approximated from the
/// AX-resolved field style with a system-font fallback — generalized on purpose, no per-app
/// metrics tables. Runs at presentation time only, never inside the focus-poll hot path, so it
/// adds no per-keystroke AX or layout cost while no suggestion is being shown.
@MainActor
enum TextLayoutCaretEstimator {
    /// Everything the estimator needs, captured as plain values so the helper stays pure and
    /// trivially testable. The caller (coordinator) owns deciding *when* estimation applies;
    /// this type only describes one attempt.
    struct Input {
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
    }

    /// A caret estimate in global Cocoa screen coordinates, plus the layout facts diagnostics
    /// want. `caretRect` matches the AX resolvers' caret shape: 2pt wide, one line tall.
    struct Estimate: Equatable {
        let caretRect: CGRect
        /// Line height of the approximated font. Carried so callers and tests can reason about
        /// the estimate without re-deriving font metrics.
        let lineHeight: CGFloat
        /// Zero-based visual line the caret landed on after soft wrapping.
        let lineIndex: Int
        /// Whether the field was treated as a multi-line editor (top-aligned content) or a
        /// single-line input (vertically centered content).
        let isMultiLineField: Bool
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

    /// Generalized layout constants. These are approximations of "typical" field chrome, not
    /// measurements of any specific host — the whole point of this v1 is to avoid per-app tables.
    /// Errors here cost a few points of offset, which is far smaller than the line-level errors
    /// of the proportional guess this replaces.
    private enum Metrics {
        /// Typical content inset between a field's border and its text. Native NSTextField uses
        /// 2-4pt; web inputs usually pad more, but overshooting pushes ghost text into the text
        /// run, so we stay near the native value.
        static let horizontalInset: CGFloat = 4
        /// Top content inset for multi-line editors.
        static let topInset: CGFloat = 4
        /// Below this width the "field" is more likely a mis-resolved AX node than a text input,
        /// and one wrap line would hold almost nothing — reject rather than guess.
        static let minimumFieldWidth: CGFloat = 40
        /// Matches the 2pt caret width the AX resolvers normalize to.
        static let caretWidth: CGFloat = 2
        /// Fields at least two line-heights tall are treated as multi-line editors; anything
        /// shorter centers its single line vertically.
        static let multiLineHeightFactor: CGFloat = 2
        /// AX-reported font sizes are host-supplied and occasionally garbage; clamp to a sane
        /// text-field range before trusting them for layout.
        static let minimumFontPointSize: CGFloat = 8
        static let maximumFontPointSize: CGFloat = 72
    }

    static func estimate(for input: Input) -> Outcome {
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
        let font = approximatedFont(for: input.fieldStyle)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let availableWidth = frame.width - 2 * Metrics.horizontalInset
        guard lineHeight > 0, availableWidth > 0 else {
            return .rejected(.fieldFrameUnusable)
        }

        let isMultiLineField = frame.height >= Metrics.multiLineHeightFactor * lineHeight

        guard let local = localCaretPosition(
            text: input.precedingText,
            font: font,
            fallbackLineHeight: lineHeight,
            availableWidth: availableWidth,
            isRightToLeft: input.isRightToLeft
        ) else {
            return .rejected(.layoutFailed)
        }

        if isMultiLineField {
            // If the laid-out content is taller than the field, the field is (or could be)
            // scrolled and we cannot know the offset, so the caret's on-screen Y is unknowable.
            if Metrics.topInset + local.contentBottom > frame.height {
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
        let screenX = frame.minX + Metrics.horizontalInset + clampedX
        let screenY: CGFloat
        if isMultiLineField {
            // Container coordinates grow downward from the content's top edge; Cocoa Y grows
            // upward. The caret rect's origin is its bottom edge.
            screenY = frame.maxY - Metrics.topInset - local.caretLineTop - caretHeight
        } else {
            screenY = frame.midY - caretHeight / 2
        }

        let estimate = Estimate(
            caretRect: CGRect(x: screenX, y: screenY, width: Metrics.caretWidth, height: caretHeight),
            lineHeight: lineHeight,
            lineIndex: local.lineIndex,
            isMultiLineField: isMultiLineField
        )
        return .estimate(estimate)
    }

    // MARK: - Font approximation

    /// Resolves the layout font from the AX-probed field style, falling back stepwise: host face
    /// at host size, system face at host size (face missing or not installed), then system face
    /// at system size. Width error compounds along the prefix, so any host-reported signal beats
    /// the pure default — but all of it stays generalized, with no per-app knowledge.
    private static func approximatedFont(for style: ResolvedFieldStyle?) -> NSFont {
        let clampedSize = (style?.fontPointSize).map {
            min(max($0, Metrics.minimumFontPointSize), Metrics.maximumFontPointSize)
        }
        let size = clampedSize ?? NSFont.systemFontSize
        if let name = style?.fontName, let font = NSFont(name: name, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size)
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
    /// fidelity the proportional guess could never reach.
    private static func localCaretPosition(
        text: String,
        font: NSFont,
        fallbackLineHeight: CGFloat,
        availableWidth: CGFloat,
        isRightToLeft: Bool
    ) -> LocalCaretPosition? {
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

        let storage = NSTextStorage(
            string: text,
            attributes: [.font: font, .paragraphStyle: paragraphStyle]
        )
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: availableWidth, height: .greatestFiniteMagnitude)
        )
        // Zero padding so container X equals content X; the field inset is applied once during
        // screen mapping instead.
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
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
            let caretHeight = extra.isEmpty ? fallbackLineHeight : max(extra.height, 1)
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
