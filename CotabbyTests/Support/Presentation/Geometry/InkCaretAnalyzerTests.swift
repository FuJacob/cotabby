import AppKit
import XCTest
@testable import Cotabby

/// The analyzer is exercised on text rendered at known positions, so the lines it finds and the
/// ink edges it reports can be checked against what was actually drawn.
final class InkCaretAnalyzerTests: XCTestCase {
    private struct Rendered {
        let bitmap: RGBABitmap
        let lineWidths: [CGFloat]
    }

    private struct Canvas {
        let font: NSFont
        let pitch: Int
        let inset: Int
        let width: Int
        let height: Int
    }

    /// Draws `lines` of light text on a dark background, one per `canvas.pitch` rows.
    private func render(lines: [String], on canvas: Canvas) -> Rendered? {
        let (font, pitch, inset, width, height) = (canvas.font, canvas.pitch, canvas.inset, canvas.width, canvas.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var widths: [CGFloat] = []
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.9, alpha: 1)]
        for (index, text) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            // Row 0 is the top in the analyzer; CGContext is bottom-up, so the baseline sits at
            // height - (index + 1) * pitch + descender room.
            let baseline = CGFloat(height) - CGFloat((index + 1) * pitch) + abs(font.descender) + 2
            context.textPosition = CGPoint(x: CGFloat(inset), y: baseline)
            CTLineDraw(line, context)
            widths.append(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        guard let image = context.makeImage(), let bitmap = RGBABitmap(image) else { return nil }
        return Rendered(bitmap: bitmap, lineWidths: widths)
    }

    func testFindsEachLineItsPitchAndWhereItsInkEnds() throws {
        let font = NSFont.systemFont(ofSize: 34)   // 17pt at 2x
        let rendered = try XCTUnwrap(render(
            lines: ["The quick brown fox jumps over the lazy dog and keeps going", "the second line ends here"],
            on: Canvas(font: font, pitch: 48, inset: 12, width: 1200, height: 100)
        ))
        let measurement = try XCTUnwrap(InkCaretAnalyzer.measure(rendered.bitmap))
        XCTAssertEqual(measurement.lines.count, 2)
        XCTAssertEqual(try XCTUnwrap(measurement.pitchRows), 48, accuracy: 1)
        for (line, width) in zip(measurement.lines, rendered.lineWidths) {
            // Ink ends within a couple of pixels of the typographic advance (the last glyph's side
            // bearing), and starts at the left margin.
            XCTAssertEqual(Double(line.inkRightColumn), Double(12) + Double(width), accuracy: 4)
            XCTAssertEqual(line.inkLeftColumn, 12, accuracy: 4)
            XCTAssertGreaterThanOrEqual(line.inkHeight, InkCaretAnalyzer.minimumLineHeightRows)
        }
        XCTAssertLessThan(measurement.lines[0].bottomRow, measurement.lines[1].topRow)
    }

    /// Measured in Obsidian: a pitch read from ink tops came out 41 rows instead of 48 when one
    /// line held ascenders and the next did not. Baselines do not move with the text.
    func testPitchComesFromBaselinesNotInkTops() throws {
        let font = NSFont.systemFont(ofSize: 34)
        let rendered = try XCTUnwrap(render(
            lines: ["The quick brown fox jumps over the lazy dog", "some rows worn as a sensor was worn"],
            on: Canvas(font: font, pitch: 48, inset: 12, width: 1200, height: 100)
        ))
        let measurement = try XCTUnwrap(InkCaretAnalyzer.measure(rendered.bitmap))
        XCTAssertEqual(measurement.lines.count, 2)
        // The second line has no ascender, so its ink top sits lower than the first line's.
        XCTAssertGreaterThan(measurement.lines[1].topRow - measurement.lines[0].topRow, 48 + 3)
        XCTAssertEqual(try XCTUnwrap(measurement.pitchRows), 48, accuracy: 1)
        for line in measurement.lines {
            XCTAssertGreaterThan(line.baselineRow, line.topRow)
            XCTAssertLessThanOrEqual(line.baselineRow, line.bottomRow + 1)
        }
        // Each baseline sits where the renderer put it: descender room + 2 rows above the pitch line.
        let expectedFirstBaseline = 48 - Int((abs(font.descender) + 2).rounded())
        XCTAssertEqual(measurement.lines[0].baselineRow, expectedFirstBaseline, accuracy: 1)
    }

    func testSingleLineHasNoPitch() throws {
        let rendered = try XCTUnwrap(render(
            lines: ["only one line"], on: Canvas(font: NSFont.systemFont(ofSize: 30), pitch: 44, inset: 10, width: 600, height: 50)
        ))
        let measurement = try XCTUnwrap(InkCaretAnalyzer.measure(rendered.bitmap))
        XCTAssertEqual(measurement.lines.count, 1)
        XCTAssertNil(measurement.pitchRows)
    }

    func testBlankCaptureMeasuresNothing() throws {
        let rendered = try XCTUnwrap(render(
            lines: [], on: Canvas(font: NSFont.systemFont(ofSize: 30), pitch: 44, inset: 10, width: 300, height: 40)
        ))
        XCTAssertNil(InkCaretAnalyzer.measure(rendered.bitmap))
    }
}
