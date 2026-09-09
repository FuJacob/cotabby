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
/// where the host's next line sits. A host that offers only one row (no line pitch, or text that
/// must not be painted over) shows the head of the suggestion that fits on it; the rest is revealed
/// as the user accepts or types through. Rows that would sit over the host's own text are backed by
/// opaque bands in the host's background color (`rowBands`) so they read as cleanly as rows over
/// blank space.
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

    /// An opaque rectangle the panel fills in the host's own background color before the glyphs
    /// are drawn, hiding the host text that would otherwise show through a ghost row.
    struct RowBand: Equatable {
        let rect: CGRect
        /// True for the band on the caret's own line, which runs from the pen to the band's right
        /// edge and hides the host text after the caret. False for a continuation row's band, which
        /// spans the whole wrap band and hides the host line the row sits on. The two are painted in
        /// separately measured colors because code editors tint the caret's line.
        let isCaretRow: Bool
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
        /// False when text follows the caret and no band will hide it: a second row would then
        /// paint over the host's own following lines.
        let allowsMultipleRows: Bool
        /// Width reserved after the text for the accept-key pill (0 when hidden).
        let keycapWidth: CGFloat
        /// True when the panel will fill row bands in the host's background color: the color is
        /// known and host text lies under the rows. Bands exist only then and count toward
        /// `contentBounds`.
        let paintsRowBands: Bool
        /// True when host text follows the caret on its own line; with `paintsRowBands` the caret
        /// row gets a band from the pen to the band's right edge.
        let coversCaretRow: Bool
        /// The host element's frame; bands never extend past it.
        let containerFrame: CGRect?

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
            keycapWidth: CGFloat = 0,
            paintsRowBands: Bool = false,
            coversCaretRow: Bool = false,
            containerFrame: CGRect? = nil
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
            self.paintsRowBands = paintsRowBands
            self.coversCaretRow = coversCaretRow
            self.containerFrame = containerFrame
        }

        /// The same input with no room reserved for the accept-key pill.
        func withoutKeycap() -> Input {
            Input(
                fullText: fullText,
                consumedUTF16: consumedUTF16,
                font: font,
                anchorTopLeft: anchorTopLeft,
                boxHeight: boxHeight,
                baselineOffsetFromTop: baselineOffsetFromTop,
                linePitch: linePitch,
                wrapBand: wrapBand,
                isRightToLeft: isRightToLeft,
                allowsMultipleRows: allowsMultipleRows,
                keycapWidth: 0,
                paintsRowBands: paintsRowBands,
                coversCaretRow: coversCaretRow,
                containerFrame: containerFrame
            )
        }
    }

    let rows: [Row]
    let font: NSFont
    let boxHeight: CGFloat
    let baselineOffsetFromTop: CGFloat
    /// Screen rect reserved for the accept-key pill, or nil when hidden.
    let keycapFrame: CGRect?
    /// Opaque bands to paint under the rows (empty unless `Input.paintsRowBands`).
    let rowBands: [RowBand]
    /// True when only the head of the text is shown: the host offers a single row and the text did
    /// not fit it. The session still holds the whole suggestion; acceptance and type-through
    /// advance through it and reveal the rest.
    let isTruncated: Bool
    /// Union of every row's glyph box, the bands, and the keycap: what the panel must cover.
    let contentBounds: CGRect

    /// Pixel height of the accept-key pill; matches the drawn keycap in `GhostTextPanelView`.
    static let keycapHeight: CGFloat = 16
    /// Gap between the end of the ghost text and the keycap.
    static let keycapGap: CGFloat = 6
    /// Rows beyond this are a runaway suggestion, not something to paint over the host.
    static let maximumRows = 6

    /// The text still shown (everything after the consumed prefix that fit).
    var remainingText: String {
        rows.map(\.text).joined()
    }

    static func make(_ input: Input) -> GhostTextLayout? {
        let withKeycap = makeRows(input)
        // The text fits but the accept-key pill after it does not, or the pill's width is what cuts
        // the text short (a narrow single-line field such as an editor's search box): the ghost
        // matters more than its hint, so lay out again without the pill.
        guard input.keycapWidth > 0, withKeycap == nil || withKeycap?.isTruncated == true else {
            return withKeycap
        }
        return makeRows(input.withoutKeycap()) ?? withKeycap
    }

    private static func makeRows(_ input: Input) -> GhostTextLayout? {
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
        guard let wrapped = wrappedRows(input, attributed: attributed, firstPenX: firstPenX, firstBaselineY: firstBaselineY),
              let last = wrapped.rows.last
        else {
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
        let bands = rowBands(rows: wrapped.rows, input: input)
        return GhostTextLayout(
            rows: wrapped.rows,
            font: input.font,
            boxHeight: input.boxHeight,
            baselineOffsetFromTop: input.baselineOffsetFromTop,
            keycapFrame: keycapFrame,
            rowBands: bands,
            isTruncated: wrapped.isTruncated,
            contentBounds: contentBounds(rows: wrapped.rows, keycapFrame: keycapFrame, bands: bands, input: input)
        )
    }

    // MARK: - Row construction

    private struct WrappedRows {
        let rows: [Row]
        let isTruncated: Bool
    }

    /// Typesets the remaining text row by row. The first row's budget runs from the pen to the band's
    /// right edge; later rows start at the band's left edge with the full band width and step down by
    /// the measured line pitch. A host that offers one row gets the head that fits on it. Returns nil
    /// when nothing can be shown without guessing.
    private static func wrappedRows(
        _ input: Input,
        attributed: NSAttributedString,
        firstPenX: CGFloat,
        firstBaselineY: CGFloat
    ) -> WrappedRows? {
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
            if !canWrap {
                return singleRow(attributed, from: start, suggestedBreak: breakIndex, penX: penX, baselineY: baselineY)
            }
            if rows.isEmpty {
                // CoreText splits a word that does not fit its budget rather than returning nothing.
                // The host moves such a word whole to the next line, so the caret row does too.
                breakIndex = wordBoundedBreak(attributed.string as NSString, from: start, suggested: breakIndex)
            }
            if breakIndex == start {
                // Nothing fits on this row. The caret row may be skipped once: an empty row keeps its
                // place at the caret so row indices stay one per visual line (its band still covers
                // the host text after the caret). An empty continuation row means the band itself is
                // too narrow for the next word.
                guard rows.isEmpty, let pitch = input.linePitch, let band = input.wrapBand else { return nil }
                rows.append(Row(utf16Range: NSRange(location: start, length: 0), text: "", penX: penX, baselineY: baselineY, width: 0))
                penX = band.lowerBound
                baselineY -= pitch
                continue
            }
            rows.append(row(attributed, range: NSRange(location: start, length: breakIndex - start), penX: penX, baselineY: baselineY))
            start = breakIndex
            if start < total, let pitch = input.linePitch, let band = input.wrapBand {
                penX = band.lowerBound
                baselineY -= pitch
            }
        }
        return rows.isEmpty ? nil : WrappedRows(rows: rows, isTruncated: false)
    }

    /// The one row a host without a second line gets: the head that fits, stopping short of a hard
    /// newline, rather than nothing. The session keeps the whole suggestion, and every accepted or
    /// typed word reveals more of it. Nil when not even the first word fits.
    private static func singleRow(
        _ attributed: NSAttributedString,
        from start: Int,
        suggestedBreak: Int,
        penX: CGFloat,
        baselineY: CGFloat
    ) -> WrappedRows? {
        let total = attributed.length
        let text = attributed.string as NSString
        var end = suggestedBreak
        let newline = text.rangeOfCharacter(from: .newlines, options: [], range: NSRange(location: start, length: total - start))
        if newline.location != NSNotFound {
            end = min(end, newline.location)
        }
        end = wordBoundedBreak(text, from: start, suggested: end)
        let isTruncated = end < total
        if isTruncated {
            end = trimmingTrailingWhitespace(text, from: start, to: end)
        }
        guard end > start else { return nil }
        let only = row(attributed, range: NSRange(location: start, length: end - start), penX: penX, baselineY: baselineY)
        return WrappedRows(rows: [only], isTruncated: isTruncated)
    }

    private static func row(_ attributed: NSAttributedString, range: NSRange, penX: CGFloat, baselineY: CGFloat) -> Row {
        let text = (attributed.string as NSString).substring(with: range)
        let line = CTLineCreateWithAttributedString(attributed.attributedSubstring(from: range))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        return Row(utf16Range: range, text: text, penX: penX, baselineY: baselineY, width: width)
    }

    /// `suggested` when it is a word break (the end of the text, or after whitespace or punctuation);
    /// otherwise the position after the last whitespace before it, or `start` when there is none.
    /// CoreText's suggested break falls inside a word only when the word itself exceeds the budget.
    private static func wordBoundedBreak(_ text: NSString, from start: Int, suggested: Int) -> Int {
        guard suggested < text.length, suggested > start else { return suggested }
        let alphanumerics = CharacterSet.alphanumerics
        func isWordCharacter(_ index: Int) -> Bool {
            alphanumerics.contains(Unicode.Scalar(text.character(at: index)) ?? " ")
        }
        guard isWordCharacter(suggested - 1), isWordCharacter(suggested) else { return suggested }
        var index = suggested - 1
        while index > start {
            if CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(text.character(at: index - 1)) ?? "a") {
                return index
            }
            index -= 1
        }
        return start
    }

    /// A cut row ends at its last visible glyph: a hanging space would push the keycap out for no
    /// reason, and a head that is only whitespace is nothing to show (the result is then `start`).
    private static func trimmingTrailingWhitespace(_ text: NSString, from start: Int, to end: Int) -> Int {
        var trimmed = end
        while trimmed > start, CharacterSet.whitespaces.contains(Unicode.Scalar(text.character(at: trimmed - 1)) ?? " ") {
            trimmed -= 1
        }
        return trimmed
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
            rowBands: [],
            isTruncated: false,
            contentBounds: contentBounds(rows: [row], keycapFrame: keycapFrame, bands: [], input: input)
        )
    }

    // MARK: - Bands

    /// The opaque bands under the rows. Each spans one line pitch vertically so consecutive rows
    /// tile without a seam: a host with symmetric leading centers its content box in the line box,
    /// so half the extra pitch goes above a row's box and half below. The caret row's band never
    /// rises above the caret box, which would clip the previous line's descenders on hosts that put
    /// all their leading below the text (Xcode), and the last band stops at its row's box bottom.
    private static func rowBands(rows: [Row], input: Input) -> [RowBand] {
        guard input.paintsRowBands, let band = input.wrapBand, let lastIndex = rows.indices.last else { return [] }
        let pitch = max(input.linePitch ?? input.boxHeight, input.boxHeight)
        let leading = (pitch - input.boxHeight) / 2
        var bands: [RowBand] = []
        for (index, row) in rows.enumerated() {
            let boxTop = rowTop(row, input)
            let top = index == 0 ? boxTop : boxTop + leading
            let bottom = boxTop - input.boxHeight - (index == lastIndex ? 0 : leading)
            let left: CGFloat
            if index == 0 {
                guard input.coversCaretRow else { continue }
                left = row.penX
            } else {
                left = band.lowerBound
            }
            var rect = CGRect(x: left, y: bottom, width: band.upperBound - left, height: top - bottom)
            if let container = input.containerFrame {
                rect = rect.intersection(container)
            }
            guard !rect.isNull, rect.width > 0, rect.height > 0 else { continue }
            bands.append(RowBand(rect: rect, isCaretRow: index == 0))
        }
        return bands
    }

    // MARK: - Geometry helpers

    private static func rowTop(_ row: Row, _ input: Input) -> CGFloat {
        row.baselineY + input.baselineOffsetFromTop
    }

    private static func contentBounds(rows: [Row], keycapFrame: CGRect?, bands: [RowBand], input: Input) -> CGRect {
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
        for band in bands {
            union = union.union(band.rect)
        }
        if let keycapFrame {
            union = union.union(keycapFrame.insetBy(dx: -margin, dy: -margin))
        }
        return union.isNull ? .zero : union
    }
}
