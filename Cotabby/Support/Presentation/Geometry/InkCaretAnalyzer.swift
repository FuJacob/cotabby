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

        var inkHeight: Int { bottomRow - topRow + 1 }
    }

    struct Measurement: Equatable {
        let lines: [Line]
        /// Median distance between consecutive line tops, in rows; nil with fewer than two lines.
        let pitchRows: Double?
    }

    /// Same contrast and saturation rules as `InkBaselineAnalyzer`, so both analyzers agree on
    /// what counts as text: a colored caret, selection tint or spelling squiggle is not ink.
    static let inkContrast = 0.22
    static let maximumSaturation = 0.35
    /// Rows of no ink tolerated inside one line (the gap between an "i" dot and its stem, or between
    /// a body row and a lone descender), before the next inked row starts a new line.
    static let maximumIntraLineGapRows = 3
    /// A block shorter than this is a stray mark (underline, rule), not a line of text.
    static let minimumLineHeightRows = 6

    static func measure(_ bitmap: RGBABitmap) -> Measurement? {
        guard bitmap.width > 0, bitmap.height > 0 else { return nil }
        let mask = inkMask(bitmap)
        let blocks = inkedRowBlocks(rowInk: mask.rowInk)
        let lines = blocks.compactMap { line(for: $0, mask: mask.ink, width: bitmap.width) }
        guard !lines.isEmpty else { return nil }
        var pitch: Double?
        if lines.count >= 2 {
            let deltas = zip(lines, lines.dropFirst()).map { Double($1.topRow - $0.topRow) }.sorted()
            pitch = deltas[deltas.count / 2]
        }
        return Measurement(lines: lines, pitchRows: pitch)
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
        for row in block {
            for column in 0..<width where mask[row * width + column] {
                left = min(left, column)
                right = max(right, column)
            }
        }
        guard right >= 0 else { return nil }
        return Line(topRow: block.lowerBound, bottomRow: block.upperBound, inkLeftColumn: left, inkRightColumn: right)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
