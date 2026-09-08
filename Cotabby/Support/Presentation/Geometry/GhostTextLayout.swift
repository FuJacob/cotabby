import AppKit
import CoreText
import Foundation

/// File overview:
/// Places every ghost glyph on screen. The layout is computed from the *full* suggestion text and
/// a consumed-prefix count, never from the remaining tail alone: as the user types through or
/// accepts words, only the consumed count changes, so the glyphs that stay visible keep the exact
/// pixel positions they had a moment ago. That property, not any re-measurement of AX geometry, is
/// what makes acceptance and type-through look perfectly still.
///
/// Positions come from CoreText's own typesetting of the suggestion in the host's font, so the
/// remaining text starts precisely where the host's caret will be after the consumed prefix is
/// inserted (both are the same font's advance for the same characters). Wrapping uses the same
/// typesetter with the host's content band and measured line pitch, so a second row sits exactly
/// where the host's next line sits. When the host's line pitch is unknown and the text needs more
/// than one row, the layout declines (`nil`) rather than guess, and the caller shows the card.
struct GhostTextLayout: Equatable {
    /// One visual row of ghost text in global Cocoa screen coordinates.
    struct Row: Equatable {
        /// UTF-16 range of `text` inside the full suggestion.
        let utf16Range: NSRange
        let text: String
        /// Pen position of the row's first glyph (left edge for LTR, right edge for RTL).
        let penX: CGFloat
        let baselineY: CGFloat
        /// Typographic width of the row's text.
        let width: CGFloat
    }

    struct Input {
        let fullText: String
        /// UTF-16 units of `fullText` the host already contains (typed through or accepted).
        let consumedUTF16: Int
        let font: NSFont
        /// Global Cocoa point of the insertion point when nothing was consumed: the caret box's
        /// leading x and its top y.
        let anchorTopLeft: CGPoint
        /// Height of the host's caret box; rows are this tall for hit/overlap purposes.
        let boxHeight: CGFloat
        /// Distance from the caret box top to the baseline (see `GhostBaselinePolicy`).
        let baselineOffsetFromTop: CGFloat
        /// Vertical distance between the host's visual lines; nil when unmeasured.
        let linePitch: CGFloat?
        /// Horizontal band a wrapped row may occupy: the host's content left edge and the right
        /// edge text may reach. The first row starts at the anchor and may run to `right`.
        let wrapBand: ClosedRange<CGFloat>?
        let isRightToLeft: Bool
        /// False when text follows the caret: a second row would paint over it.
        let allowsMultipleRows: Bool
        /// Width reserved after the text for the accept-key pill (0 when hidden).
        let keycapWidth: CGFloat

        init(
            fullText: String,
            consumedUTF16: Int,
            font: NSFont,
            anchorTopLeft: CGPoint,
            boxHeight: CGFloat,
            baselineOffsetFromTop: CGFloat,
            linePitch: CGFloat? = nil,
            wrapBand: ClosedRange<CGFloat>? = nil,
            isRightToLeft: Bool = false,
            allowsMultipleRows: Bool = true,
            keycapWidth: CGFloat = 0
        ) {
            self.fullText = fullText
            self.consumedUTF16 = consumedUTF16
            self.font = font
            self.anchorTopLeft = anchorTopLeft
            self.boxHeight = boxHeight
            self.baselineOffsetFromTop = baselineOffsetFromTop
            self.linePitch = linePitch
            self.wrapBand = wrapBand
            self.isRightToLeft = isRightToLeft
            self.allowsMultipleRows = allowsMultipleRows
            self.keycapWidth = keycapWidth
        }
    }

    let rows: [Row]
    let font: NSFont
    let boxHeight: CGFloat
    let baselineOffsetFromTop: CGFloat
    /// Screen rect reserved for the accept-key pill, or nil when hidden.
    let keycapFrame: CGRect?
    /// Union of every row's glyph box plus the keycap: what the panel must cover.
    let contentBounds: CGRect

    /// Pixel height of the accept-key pill; matches the drawn keycap in `GhostTextPanelView`.
    static let keycapHeight: CGFloat = 16
    /// Gap between the end of the ghost text and the keycap.
    static let keycapGap: CGFloat = 6
    /// Rows beyond this are a runaway suggestion, not something to paint over the host.
    static let maximumRows = 6

    /// The text still shown (everything after the consumed prefix).
    var remainingText: String {
        rows.map(\.text).joined()
    }

    static func make(_ input: Input) -> GhostTextLayout? {
        let total = (input.fullText as NSString).length
        guard input.consumedUTF16 >= 0, input.consumedUTF16 < total, input.boxHeight > 0 else {
            return nil
        }
        let attributed = NSAttributedString(string: input.fullText, attributes: [.font: input.font])
        let fullLine = CTLineCreateWithAttributedString(attributed)
        let consumedAdvance = CTLineGetOffsetForStringIndex(fullLine, input.consumedUTF16, nil)
        let firstBaselineY = input.anchorTopLeft.y - input.baselineOffsetFromTop

        if input.isRightToLeft {
            return rightToLeftLayout(input, attributed: attributed, firstBaselineY: firstBaselineY)
        }

        let firstPenX = input.anchorTopLeft.x + consumedAdvance
        let rows = wrappedRows(input, attributed: attributed, firstPenX: firstPenX, firstBaselineY: firstBaselineY)
        guard let rows, let last = rows.last else {
            return nil
        }
        let keycapFrame: CGRect? = input.keycapWidth > 0
            ? CGRect(
                x: last.penX + last.width + keycapGap,
                y: rowTop(last, input) - (input.boxHeight + keycapHeight) / 2,
                width: input.keycapWidth,
                height: keycapHeight
            )
            : nil
        return GhostTextLayout(
            rows: rows,
            font: input.font,
            boxHeight: input.boxHeight,
            baselineOffsetFromTop: input.baselineOffsetFromTop,
            keycapFrame: keycapFrame,
            contentBounds: contentBounds(rows: rows, keycapFrame: keycapFrame, input: input)
        )
    }

    // MARK: - Row construction

    /// Typesets the remaining text row by row. The first row's budget runs from the pen to the band's
    /// right edge; later rows start at the band's left edge with the full band width and step down by
    /// the measured line pitch. Returns nil when the text cannot be shown without guessing.
    private static func wrappedRows(
        _ input: Input,
        attributed: NSAttributedString,
        firstPenX: CGFloat,
        firstBaselineY: CGFloat
    ) -> [Row]? {
        let total = attributed.length
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let canWrap = input.allowsMultipleRows && input.linePitch != nil && input.wrapBand != nil

        var rows: [Row] = []
        var start = input.consumedUTF16
        var penX = firstPenX
        var baselineY = firstBaselineY
        while start < total {
            guard rows.count < maximumRows else { return nil }
            let budget: CGFloat
            if let band = input.wrapBand {
                budget = max(0, band.upperBound - penX - (canWrap ? 0 : input.keycapWidth))
            } else {
                budget = .greatestFiniteMagnitude
            }
            var breakIndex = start + CTTypesetterSuggestLineBreak(typesetter, start, Double(budget))
            let isLastRow = breakIndex >= total
            if !canWrap {
                // Single row only: the whole remainder must fit (a hard newline also cannot be shown).
                let remainder = (attributed.string as NSString).substring(from: start)
                guard isLastRow, !remainder.contains(where: \.isNewline) else { return nil }
                breakIndex = total
            } else if breakIndex == start {
                // Nothing fits on this row. Move to the next row once; a second empty row means the
                // band itself is too narrow for the next word.
                guard rows.isEmpty || !(rows.last?.text.isEmpty ?? true), let pitch = input.linePitch,
                      let band = input.wrapBand else { return nil }
                if !rows.isEmpty { return nil }
                penX = band.lowerBound
                baselineY -= pitch
                rows.append(Row(utf16Range: NSRange(location: start, length: 0), text: "", penX: penX, baselineY: baselineY, width: 0))
                continue
            }
            let rowRange = NSRange(location: start, length: breakIndex - start)
            let rowText = (attributed.string as NSString).substring(with: rowRange)
            let rowLine = CTLineCreateWithAttributedString(attributed.attributedSubstring(from: rowRange))
            let width = CGFloat(CTLineGetTypographicBounds(rowLine, nil, nil, nil))
            if let last = rows.last, last.text.isEmpty {
                rows.removeLast()
            }
            rows.append(Row(utf16Range: rowRange, text: rowText, penX: penX, baselineY: baselineY, width: width))
            start = breakIndex
            if start < total, let pitch = input.linePitch, let band = input.wrapBand {
                penX = band.lowerBound
                baselineY -= pitch
            }
        }
        return rows.isEmpty ? nil : rows
    }

    /// Right-to-left hosts: a single row whose trailing (right) edge sits at the caret. Multi-row
    /// RTL wrapping is declined so the card handles it.
    private static func rightToLeftLayout(
        _ input: Input,
        attributed: NSAttributedString,
        firstBaselineY: CGFloat
    ) -> GhostTextLayout? {
        let total = attributed.length
        let range = NSRange(location: input.consumedUTF16, length: total - input.consumedUTF16)
        let text = (attributed.string as NSString).substring(with: range)
        guard !text.contains(where: \.isNewline) else { return nil }
        let line = CTLineCreateWithAttributedString(attributed.attributedSubstring(from: range))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let row = Row(utf16Range: range, text: text, penX: input.anchorTopLeft.x - width, baselineY: firstBaselineY, width: width)
        let keycapFrame: CGRect? = input.keycapWidth > 0
            ? CGRect(
                x: row.penX - keycapGap - input.keycapWidth,
                y: rowTop(row, input) - (input.boxHeight + keycapHeight) / 2,
                width: input.keycapWidth,
                height: keycapHeight
            )
            : nil
        return GhostTextLayout(
            rows: [row],
            font: input.font,
            boxHeight: input.boxHeight,
            baselineOffsetFromTop: input.baselineOffsetFromTop,
            keycapFrame: keycapFrame,
            contentBounds: contentBounds(rows: [row], keycapFrame: keycapFrame, input: input)
        )
    }

    // MARK: - Geometry helpers

    private static func rowTop(_ row: Row, _ input: Input) -> CGFloat {
        row.baselineY + input.baselineOffsetFromTop
    }

    private static func contentBounds(rows: [Row], keycapFrame: CGRect?, input: Input) -> CGRect {
        // Glyph ink can overhang the typographic box (italics, descender swashes, subpixel
        // anti-aliasing), so each row's box is the font's full ascent/descent plus a small margin.
        let margin: CGFloat = 3
        var union = CGRect.null
        for row in rows {
            let rowRect = CGRect(
                x: row.penX - margin,
                y: row.baselineY + input.font.descender - margin,
                width: row.width + margin * 2,
                height: input.font.ascender - input.font.descender + margin * 2
            )
            union = union.union(rowRect)
        }
        if let keycapFrame {
            union = union.union(keycapFrame.insetBy(dx: -margin, dy: -margin))
        }
        return union.isNull ? .zero : union
    }
}
