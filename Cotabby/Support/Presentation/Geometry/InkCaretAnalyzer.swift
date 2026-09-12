import CoreGraphics
import Foundation

/// File overview:
/// Finds the visual text lines inside a capture of one paragraph and where each line's ink ends.
///
/// Why this exists: some editors expose no per-line and no per-character geometry through
/// Accessibility at all. Obsidian's CodeMirror is the measured case: a paragraph is ONE static-text
/// element whose frame is the union of its wrapped lines, every bounds query (NSRange and
/// text-marker alike) answers a zero-size rect, and the font attributes are empty. Nothing can be
/// asked for the caret's line or x. The pixels the host paints are the one measurement left, and
/// they are exactly what the user's eye judges the ghost against.
///
/// The analyzer is pure (bitmap in, rows and columns out) so the detection rules are unit-tested
/// on text rendered at known positions. Coordinates are bitmap rows/columns; `PixelCaretLocator`
/// maps them back to screen points using the capture rectangle it asked for.
enum InkCaretAnalyzer {
    struct Line: Equatable {
        /// First and last bitmap rows carrying ink (inclusive).
        let topRow: Int
        let bottomRow: Int
        /// First and last bitmap columns carrying ink on this line (inclusive).
        let inkLeftColumn: Int
        let inkRightColumn: Int
        /// The first row below this line's letter bodies: the longest contiguous block of rows at
        /// least `bodyThreshold` as busy as the line's busiest row (see `bodyRows(in:threshold:)`).
        /// Unlike the ink top, which moves with whether the line happens to hold an ascender, the
        /// baseline is where every line's letters sit, so it is what the pitch and the caret line's
        /// baseline are read from. 0 when unknown.
        var baselineRow: Int = 0
        /// The host's own caret bar at the right end of the line, when the capture caught it (see
        /// `trailingCaretBar`); `inkRightColumn` then includes it. Nil when there is none.
        var caretBarColumns: ClosedRange<Int>?
        /// The last column of text ink left of a caret bar; nil when there is no bar.
        var glyphRightColumn: Int?

        var inkHeight: Int { bottomRow - topRow + 1 }
        /// The right edge of the line's text, whatever the caret bar did.
        var textRightColumn: Int { glyphRightColumn ?? inkRightColumn }
    }

    struct Measurement: Equatable {
        let lines: [Line]
        /// Median distance between consecutive line baselines, in rows; nil with fewer than two
        /// lines. Measured 2026-09-10 in Obsidian: the distance between ink TOPS read 41 rows for
        /// a 48-row pitch when one line had ascenders and the next had none, and the caret line's
        /// box landed 3.5pt high.
        let pitchRows: Double?
    }

    /// Rows at least this fraction as busy as a line's busiest row are its letter bodies.
    static let bodyThreshold = 0.35

    /// Same contrast and saturation rules as `InkBaselineAnalyzer`, so both analyzers agree on
    /// what counts as text: a colored caret, selection tint or spelling squiggle is not ink.
    static let inkContrast = 0.22
    static let maximumSaturation = 0.35
    /// Rows of no ink tolerated inside one line (the gap between an "i" dot and its stem, or between
    /// a body row and a lone descender), before the next inked row starts a new line.
    static let maximumIntraLineGapRows = 3
    /// A block shorter than this is a stray mark (underline, rule), not a line of text.
    static let minimumLineHeightRows = 6
    /// Widest caret bar a host draws, in device pixels: CodeMirror's 1.2px caret covers two or three
    /// at 2x.
    static let maximumCaretBarColumns = 4
    /// Fraction of its line's rows a caret column is inked on. The bar spans the whole line box,
    /// taller than any letter: measured 2026-09-10 in Obsidian, 38 of 38 rows for the bar against
    /// 13 to 18 for the letters beside it.
    static let caretBarFill = 0.9

    /// A vertical stroke of ink: the host's caret bar when `standingCaretBar` finds one.
    struct Stroke: Equatable {
        let columns: ClosedRange<Int>
        let rows: ClosedRange<Int>
    }

    /// How much taller than every other column's ink a stroke must be to be the caret. The caret
    /// spans the font's whole ascent and descent, which no glyph does: measured 2026-09-11 in
    /// Claude's composer (Anthropic Sans at 15.3pt, 2x), a 38-row caret beside 24-row stems; a "|"
    /// reaches 30.
    static let caretBarHeightRatio = 1.3
    /// Fraction of a stroke's rows the columns beside it may be inked on while it still stands apart
    /// from the text: the last glyph's bowl can reach the caret's neighbouring column on its body rows.
    static let caretBarNeighbourFill = 0.5

    static func measure(_ bitmap: RGBABitmap) -> Measurement? {
        guard bitmap.width > 0, bitmap.height > 0 else { return nil }
        let mask = inkMask(bitmap)
        // The caret is found before the lines and set aside while they are: under a tight line
        // height it reaches from its own line's box to within a device row or two of the line above's
        // descenders, and read as ink those rows joined the two lines into one block. Claude's
        // composer (2026-09-11, 20pt pitch, a 19.2pt caret): every capture after a wrap came back as
        // one line, the caret at the end of the FIRST line, and the ghost there, a line off.
        let bar = standingCaretBar(mask: mask.ink, width: bitmap.width, height: bitmap.height)
        var rowInk = mask.rowInk
        if let bar {
            for row in bar.rows {
                for column in bar.columns where mask.ink[row * bitmap.width + column] {
                    rowInk[row] -= 1
                }
            }
        }
        let blocks = giving(bar, to: inkedRowBlocks(rowInk: rowInk))
        let lines = blocks.compactMap { line(for: $0, mask: mask.ink, width: bitmap.width) }
        guard !lines.isEmpty else { return nil }
        return Measurement(lines: lines, pitchRows: pitchRows(of: lines))
    }

    /// How far below a line's baseline the next one's may start, as a fraction of the taller of the
    /// two lines' ink: two lines are separate blocks, so the lower one's baseline lies at least its
    /// ascent plus the upper one's descent below the upper one's, about their ink height.
    static let minimumPitchInkFraction = 0.8

    /// Median distance between consecutive baselines, from the pairs whose distance is a pitch at
    /// all. A line holding one capital has no letter body to find a baseline under: its first busy
    /// rows are the capital's top bar. Measured 2026-09-11 in Claude's composer: an "E" typed onto a
    /// fresh line read 25 rows below the line above's baseline for a 44-row pitch, the frame then
    /// held three line boxes of 12.5pt, and ten ghosts were drawn at the start of a line that did not
    /// exist. Nil when no pair qualifies; the caller has other sources of a pitch.
    static func pitchRows(of lines: [Line]) -> Double? {
        let deltas = zip(lines, lines.dropFirst()).compactMap { upper, lower -> Double? in
            let delta = Double(lower.baselineRow - upper.baselineRow)
            let tallest = Double(max(upper.inkHeight, lower.inkHeight))
            return delta >= minimumPitchInkFraction * tallest ? delta : nil
        }.sorted()
        return deltas.isEmpty ? nil : deltas[deltas.count / 2]
    }

    private struct InkMask {
        let ink: [Bool]
        let rowInk: [Int]
    }

    /// Which pixels are text: unsaturated pixels contrasting with the median (background) luminance.
    private static func inkMask(_ bitmap: RGBABitmap) -> InkMask {
        let width = bitmap.width
        let height = bitmap.height
        var luminance = [Double](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                luminance[row * width + column] = bitmap.pixel(column: column, row: row).luminance
            }
        }
        let background = median(luminance)
        var ink = [Bool](repeating: false, count: width * height)
        var rowInk = [Int](repeating: 0, count: height)
        for row in 0..<height {
            for column in 0..<width {
                let pixel = bitmap.pixel(column: column, row: row)
                let maxChannel = max(pixel.red, pixel.green, pixel.blue)
                let minChannel = min(pixel.red, pixel.green, pixel.blue)
                let saturation = maxChannel > 0 ? (maxChannel - minChannel) / maxChannel : 0
                if abs(luminance[row * width + column] - background) > inkContrast, saturation < maximumSaturation {
                    ink[row * width + column] = true
                    rowInk[row] += 1
                }
            }
        }
        return InkMask(ink: ink, rowInk: rowInk)
    }

    /// The host's caret bar, when the capture caught one standing apart from the text: the tallest
    /// column's run of ink, widened over the neighbouring columns that run over nearly the same rows
    /// (a caret at a fractional position covers two or three), no wider than
    /// `maximumCaretBarColumns`, clear of the ink beside it (`caretBarNeighbourFill`), and taller
    /// than every other column's ink by `caretBarHeightRatio`. Nil when the tallest stroke is
    /// anything else (a glyph, a block, a caret the blink hid): the lines are then found exactly as
    /// they were before the bar was looked for.
    static func standingCaretBar(mask: [Bool], width: Int, height: Int) -> Stroke? {
        let runs = longestInkRuns(mask: mask, width: width, height: height)
        guard let tallest = runs.indices.max(by: { (runs[$0]?.count ?? 0) < (runs[$1]?.count ?? 0) }),
              let core = runs[tallest], core.count >= minimumLineHeightRows else { return nil }
        func joins(_ column: Int) -> Bool {
            guard column >= 0, column < width, let run = runs[column] else { return false }
            let shared = min(run.upperBound, core.upperBound) - max(run.lowerBound, core.lowerBound) + 1
            return Double(shared) >= 0.8 * Double(core.count)
        }
        var left = tallest
        var right = tallest
        while right - left + 1 < maximumCaretBarColumns, joins(left - 1) { left -= 1 }
        while right - left + 1 < maximumCaretBarColumns, joins(right + 1) { right += 1 }
        // Still stroke-like past the widest caret: a block of ink, not a caret.
        guard !joins(left - 1), !joins(right + 1) else { return nil }
        var rows = core
        for column in left...right {
            if let run = runs[column] { rows = min(rows.lowerBound, run.lowerBound)...max(rows.upperBound, run.upperBound) }
        }
        func fill(_ column: Int) -> Double {
            guard column >= 0, column < width else { return 0 }
            return Double(rows.filter { mask[$0 * width + column] }.count) / Double(rows.count)
        }
        guard fill(left - 1) <= caretBarNeighbourFill, fill(right + 1) <= caretBarNeighbourFill else { return nil }
        var others = 0
        for column in runs.indices where column < left - 1 || column > right + 1 {
            others = max(others, runs[column]?.count ?? 0)
        }
        guard others >= minimumLineHeightRows, Double(core.count) >= caretBarHeightRatio * Double(others) else { return nil }
        return Stroke(columns: left...right, rows: rows)
    }

    /// Each column's longest unbroken run of ink rows, nil for a column with none.
    private static func longestInkRuns(mask: [Bool], width: Int, height: Int) -> [ClosedRange<Int>?] {
        var runs = [ClosedRange<Int>?](repeating: nil, count: width)
        for column in 0..<width {
            var best: ClosedRange<Int>?
            var start: Int?
            for row in 0...height {
                if row < height, mask[row * width + column] {
                    if start == nil { start = row }
                } else if let begun = start {
                    if row - begun > (best?.count ?? 0) { best = begun...(row - 1) }
                    start = nil
                }
            }
            runs[column] = best
        }
        return runs
    }

    /// The blocks with the caret bar's rows given back to the line it stands on: the block sharing
    /// most of its rows, grown over the rest but never into a neighbouring block. A caret on a line
    /// that holds nothing else is that line's only ink, as it was before the bar was set aside.
    private static func giving(_ bar: Stroke?, to blocks: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        guard let bar else { return blocks }
        func shared(_ block: ClosedRange<Int>) -> Int {
            max(0, min(block.upperBound, bar.rows.upperBound) - max(block.lowerBound, bar.rows.lowerBound) + 1)
        }
        var result = blocks
        if let index = blocks.indices.max(by: { shared(blocks[$0]) < shared(blocks[$1]) }), shared(blocks[index]) > 0 {
            let floor = index > 0 ? blocks[index - 1].upperBound + 1 : 0
            let ceiling = index + 1 < blocks.count ? blocks[index + 1].lowerBound - 1 : Int.max
            result[index] = min(blocks[index].lowerBound, max(bar.rows.lowerBound, floor))
                ... max(blocks[index].upperBound, min(bar.rows.upperBound, ceiling))
            return result
        }
        let floor = blocks.last(where: { $0.upperBound < bar.rows.lowerBound }).map { $0.upperBound + 1 } ?? 0
        let ceiling = blocks.first(where: { $0.lowerBound > bar.rows.upperBound }).map { $0.lowerBound - 1 } ?? Int.max
        let lower = max(bar.rows.lowerBound, floor)
        let upper = min(bar.rows.upperBound, ceiling)
        guard lower <= upper else { return blocks }
        result.append(lower...upper)
        return result.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Contiguous blocks of inked rows, allowing short gaps inside a line (an "i" dot above its
    /// stem, a lone descender below the bodies).
    private static func inkedRowBlocks(rowInk: [Int]) -> [ClosedRange<Int>] {
        var blocks: [ClosedRange<Int>] = []
        var start: Int?
        var lastInked = 0
        for row in rowInk.indices {
            if rowInk[row] > 0 {
                if start == nil { start = row }
                lastInked = row
            } else if let begun = start, row - lastInked > maximumIntraLineGapRows {
                blocks.append(begun...lastInked)
                start = nil
            }
        }
        if let begun = start { blocks.append(begun...lastInked) }
        return blocks
    }

    private static func line(for block: ClosedRange<Int>, mask: [Bool], width: Int) -> Line? {
        guard block.count >= minimumLineHeightRows else { return nil }
        var left = Int.max
        var right = -1
        var rowInk: [Int] = []
        for row in block {
            var count = 0
            for column in 0..<width where mask[row * width + column] {
                left = min(left, column)
                right = max(right, column)
                count += 1
            }
            rowInk.append(count)
        }
        guard right >= 0, let peak = rowInk.max(), peak > 0 else { return nil }
        // Letter bodies: the longest run of busy rows; the baseline is the row after it.
        let bodies = bodyRows(in: rowInk, threshold: bodyThreshold * Double(peak))
        let baseline = bodies.map { block.lowerBound + $0.upperBound + 1 } ?? block.upperBound + 1
        var line = Line(
            topRow: block.lowerBound, bottomRow: block.upperBound, inkLeftColumn: left, inkRightColumn: right, baselineRow: baseline
        )
        if let found = trailingCaretBar(block: block, columns: left...right, baseline: baseline, mask: mask, width: width) {
            line.caretBarColumns = found.bar
            line.glyphRightColumn = found.textRight
        }
        return line
    }

    /// Least share of a line's rows a later busy run must span to be taken for its letter bodies
    /// over the first: an x-height band is nearly half the line (17 of the 38 rows beside Claude's
    /// caret), a capital's bar a tenth.
    static let minimumBodyShare = 0.3

    /// A line's letter bodies, as indices into `rowInk` (the line's rows, top first): the first run
    /// of rows at least `threshold` busy, unless a longer run spanning `minimumBodyShare` of the rows
    /// follows it, which is then the bodies.
    ///
    /// A capital's top curve, with the ascender tops beside it, passes the threshold on its own above
    /// a dip where only stems remain: Claude's Code composer (2026-09-11) read "Should" with the
    /// baseline under the S's top curve, 5.5pt below the caret box's top for the true 15.0, and drew
    /// the ghost nine points high. Over 4,823 dumped reads the first run put 245 of 2,736 single-line
    /// baselines a third of the way into the caret box instead of four fifths; with the longer run
    /// taken none is there, and 267 reads change, not one of them away from four fifths. A lone
    /// capital keeps its first run: its bars are about equal, none spans a third of the line, and a
    /// lower bar is no baseline (an "F"'s middle bar would give a pitch eleven rows short). The
    /// calibrator's rule, which bridges dips of two rows (`InkBaselineAnalyzer.maximumBodyGapRows`),
    /// closes the dip too but also bridges down into a "g"'s bowl under the baseline: Chrome's
    /// address bar read "is g" and "goo" 2.5pt low with it.
    static func bodyRows(in rowInk: [Int], threshold: Double) -> ClosedRange<Int>? {
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        for index in 0...rowInk.count {
            if index < rowInk.count, Double(rowInk[index]) >= threshold {
                if start == nil { start = index }
            } else if let begun = start {
                runs.append(begun...(index - 1))
                start = nil
            }
        }
        guard let first = runs.first else { return nil }
        var longest = first
        for run in runs where run.count > longest.count {
            longest = run
        }
        guard longest != first, Double(longest.count) >= minimumBodyShare * Double(rowInk.count) else {
            return first
        }
        return longest
    }

    /// The host's caret bar at the right end of a line's ink, when the capture caught it: one to
    /// `maximumCaretBarColumns` columns inked on nearly every row of the line and reaching below the
    /// letters' baseline, with text to their left. A final "l" or "I" also fills a line that has no
    /// descenders, but it stops at the baseline. The caret is drawn in the text colour (Obsidian),
    /// so it passes the saturation rule, and read as the last glyph it put the caret a point right,
    /// five after a trailing space (measured 2026-09-10). `columns` is the line's ink, left to right.
    /// Returns the bar and the last text column.
    static func trailingCaretBar(
        block: ClosedRange<Int>, columns: ClosedRange<Int>, baseline: Int, mask: [Bool], width: Int
    ) -> (bar: ClosedRange<Int>, textRight: Int)? {
        let left = columns.lowerBound
        let right = columns.upperBound
        let needed = Int((Double(block.count) * caretBarFill).rounded(.up))
        let belowBaseline = max(2, block.count / 10)
        func isBarColumn(_ column: Int) -> Bool {
            var inked = 0
            var lowest = -1
            for row in block where mask[row * width + column] {
                inked += 1
                lowest = row
            }
            return inked >= needed && lowest >= baseline + belowBaseline
        }
        var barLeft = right + 1
        while barLeft - 1 >= left, right - (barLeft - 1) < maximumCaretBarColumns, isBarColumn(barLeft - 1) {
            barLeft -= 1
        }
        guard barLeft <= right else { return nil }
        // Still bar-like past the widest caret: a block of ink, not a caret.
        if barLeft - 1 >= left, isBarColumn(barLeft - 1) { return nil }
        var textRight = barLeft - 1
        while textRight >= left, !block.contains(where: { mask[$0 * width + textRight] }) {
            textRight -= 1
        }
        guard textRight >= left else { return nil }
        return (barLeft...right, textRight)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
