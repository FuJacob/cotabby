import AppKit
import XCTest
@testable import Cotabby

final class InkBaselineAnalyzerTests: XCTestCase {
    /// Renders `text` with `font` into a 2x bitmap whose baseline sits exactly `baselineFromTop`
    /// points below the top (CoreText draws the line at an explicit baseline, the same way the ghost
    /// panel does), over `background`, optionally with a saturated underline (a spelling squiggle
    /// stand-in) two points below the baseline. Returns the image and the baseline row in pixels.
    private func render(
        _ text: String,
        font: NSFont,
        baselineFromTop: CGFloat,
        background: NSColor,
        ink: NSColor,
        underline: NSColor? = nil
    ) -> (CGImage, Int) {
        let scale: CGFloat = 2
        let size = CGSize(width: 220, height: 30)
        let context = CGContext(
            data: nil,
            width: Int(size.width * scale),
            height: Int(size.height * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(background.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink])
        let line = CTLineCreateWithAttributedString(attributed)
        // CGContext bitmaps have a bottom-left origin: the baseline is `baselineFromTop` below the top.
        context.textPosition = CGPoint(x: 4, y: size.height - baselineFromTop)
        CTLineDraw(line, context)
        if let underline {
            context.setFillColor(underline.cgColor)
            context.fill(CGRect(x: 4, y: size.height - baselineFromTop - 2.5, width: 200, height: 1))
        }
        return (context.makeImage()!, Int((baselineFromTop * scale).rounded()))
    }

    func testFindsTheBaselineOfDarkTextOnLight() {
        let (image, expectedRow) = render(
            "Field two alpha bravo charlie x", font: NSFont(name: "Helvetica", size: 16)!,
            baselineFromTop: 18.5, background: .white, ink: .black
        )
        let measurement = InkBaselineAnalyzer.measure(image)
        XCTAssertNotNil(measurement)
        XCTAssertEqual(measurement?.baselineRow ?? -99, expectedRow, accuracy: 1)
    }

    func testFindsTheBaselineOfLightTextOnDark() {
        let (image, expectedRow) = render(
            "quick brown fox jumps", font: NSFont(name: "Menlo-Regular", size: 13)!,
            baselineFromTop: 14, background: NSColor(white: 0.12, alpha: 1), ink: NSColor(white: 0.9, alpha: 1)
        )
        let measurement = InkBaselineAnalyzer.measure(image)
        XCTAssertEqual(measurement?.baselineRow ?? -99, expectedRow, accuracy: 1)
    }

    func testDescendersAndASaturatedSquiggleDoNotPullTheBaselineDown() {
        let (image, expectedRow) = render(
            "typing jumps quickly", font: NSFont(name: "Georgia", size: 18)!,
            baselineFromTop: 20, background: .white, ink: .black, underline: .red
        )
        let measurement = InkBaselineAnalyzer.measure(image)
        XCTAssertEqual(measurement?.baselineRow ?? -99, expectedRow, accuracy: 1)
    }

    func testAGrayUnderlineBelowTheBaselineIsNotTheBaseline() {
        // Safari's spell-check squiggle antialiases to a low-saturation gray band; it spans the whole
        // word, so it out-inks any descender row, yet it must not move the measured baseline.
        let (image, expectedRow) = render(
            "juliet kilo lima mike november x", font: NSFont(name: "Georgia", size: 18)!,
            baselineFromTop: 20.5, background: .white, ink: .black, underline: NSColor(white: 0.55, alpha: 1)
        )
        let measurement = InkBaselineAnalyzer.measure(image)
        XCTAssertEqual(measurement?.baselineRow ?? -99, expectedRow, accuracy: 1)
    }

    /// Measured 2026-09-10 on "Continue. Make it PERFECT." in Claude's composer: right under the cap
    /// tops one row held 68 inked pixels against a threshold of 69, and the first busy block ended
    /// there, so the baseline read 18 rows above the letters. A dip of a row or two inside the
    /// bodies is a row of stems, not the descender space; only a deeper gap ends the bodies.
    func testAThinDipInsideTheLetterBodiesDoesNotEndThem() {
        // Per-row ink counts of a 40-row strip: cap tops, a one-row dip, the bodies, then nothing.
        var rowInk = [Int](repeating: 0, count: 40)
        for row in 10..<14 { rowInk[row] = 100 }
        rowInk[14] = 30
        for row in 15..<30 { rowInk[row] = 100 }
        let measurement = InkBaselineAnalyzer.measure(strip(rowInk: rowInk, width: 200))
        XCTAssertEqual(measurement?.bodyTopRow, 10)
        XCTAssertEqual(measurement?.baselineRow, 30)
    }

    func testAGapDeeperThanTwoRowsStillSeparatesAnUnderlineFromTheBodies() {
        var rowInk = [Int](repeating: 0, count: 40)
        for row in 10..<24 { rowInk[row] = 100 }
        for row in 27..<29 { rowInk[row] = 100 }  // an underline three rows below the baseline
        let measurement = InkBaselineAnalyzer.measure(strip(rowInk: rowInk, width: 200))
        XCTAssertEqual(measurement?.baselineRow, 24)
    }

    /// A strip whose rows carry exactly the given number of dark pixels on a white ground.
    private func strip(rowInk: [Int], width: Int) -> RGBABitmap {
        var bytes: [UInt8] = []
        for count in rowInk {
            for column in 0..<width {
                let dark = column < count
                let value: UInt8 = dark ? 20 : 255
                bytes += [value, value, value, 255]
            }
        }
        return RGBABitmap(width: width, height: rowInk.count, bytes: bytes)
    }

    func testEmptyStripYieldsNothing() {
        let (image, _) = render("", font: NSFont.systemFont(ofSize: 15), baselineFromTop: 15, background: .white, ink: .black)
        XCTAssertNil(InkBaselineAnalyzer.measure(image))
    }
}
