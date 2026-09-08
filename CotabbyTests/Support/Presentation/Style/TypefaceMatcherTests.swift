import AppKit
import XCTest
@testable import Cotabby

/// Strips are rendered here the way a browser paints them (dark text on a light field, or light on
/// dark, at 2x) and the matcher must name the face they were drawn in.
final class TypefaceMatcherTests: XCTestCase {
    private let scale: CGFloat = 2
    private let stripSize = CGSize(width: 240, height: 24)

    private func strip(_ text: String, font: NSFont, baselineFromTop: CGFloat, dark: Bool = false) -> (RGBABitmap, CGFloat) {
        let width = Int(stripSize.width * scale)
        let height = Int(stripSize.height * scale)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(dark ? CGColor(gray: 0.1, alpha: 1) : CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: stripSize))
        let attributed = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: dark ? NSColor(white: 0.92, alpha: 1) : NSColor.black]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let caretX = stripSize.width - 6
        context.textPosition = CGPoint(x: caretX - advance, y: stripSize.height - baselineFromTop)
        CTLineDraw(line, context)
        return (RGBABitmap(context.makeImage()!)!, caretX * scale)
    }

    private func match(_ text: String, font: NSFont, dark: Bool = false) -> TypefaceMatcher.Match? {
        let baseline: CGFloat = 17
        let (bitmap, caretColumn) = strip(text, font: font, baselineFromTop: baseline, dark: dark)
        return TypefaceMatcher.match(
            TypefaceMatcher.Input(
                strip: bitmap, scale: scale, caretColumn: caretColumn, baselineRow: baseline * scale,
                text: text, pointSize: font.pointSize, candidates: TypefaceMatcher.defaultCandidates(pointSize: font.pointSize)
            )
        )
    }

    func testIdentifiesGeorgia() {
        let match = match("Field three alpha bravo charlie x", font: NSFont(name: "Georgia", size: 18)!)
        XCTAssertEqual(match?.familyName, "Georgia", "\(String(describing: match))")
    }

    func testIdentifiesMenloOnADarkField() {
        let match = match("The quick brown fox jumps", font: NSFont(name: "Menlo-Regular", size: 13)!, dark: true)
        XCTAssertEqual(match?.familyName, "Menlo", "\(String(describing: match))")
    }

    func testIdentifiesTheSystemFace() {
        let match = match("Field four alpha bravo charlie", font: NSFont.systemFont(ofSize: 15))
        XCTAssertEqual(match?.familyName, NSFont.systemFont(ofSize: 15).familyName, "\(String(describing: match))")
    }

    func testDoesNotConfuseHelveticaWithGeorgia() {
        let match = match("Field two alpha bravo charlie x", font: NSFont(name: "Helvetica", size: 16)!)
        XCTAssertNotEqual(match?.familyName, "Georgia")
        XCTAssertNotEqual(match?.familyName, "Menlo")
    }

    func testOnlyTheLineTailOnScreenStillMatchesOrDeclines() {
        // The caret sits shortly after a soft wrap: the strip shows only "charlie x" although the
        // paragraph text before the caret is longer. A wrong face is worse than no answer.
        let (bitmap, caretColumn) = strip("charlie x", font: NSFont(name: "Georgia", size: 18)!, baselineFromTop: 17)
        let match = TypefaceMatcher.match(
            TypefaceMatcher.Input(
                strip: bitmap, scale: scale, caretColumn: caretColumn, baselineRow: 34,
                text: "Field three alpha bravo charlie x", pointSize: 18,
                candidates: TypefaceMatcher.defaultCandidates(pointSize: 18)
            )
        )
        if let match {
            XCTAssertEqual(match.familyName, "Georgia")
        }
    }

    /// The production strip stops two points short of the caret, so the caret column lies beyond the
    /// bitmap's right edge. This crashed the app once (index out of range); it must simply work.
    func testCaretColumnBeyondTheStripIsHandled() {
        let font = NSFont(name: "Georgia", size: 18)!
        let (bitmap, _) = strip("Field three alpha bravo charlie x", font: font, baselineFromTop: 17)
        let match = TypefaceMatcher.match(
            TypefaceMatcher.Input(
                strip: bitmap, scale: scale, caretColumn: CGFloat(bitmap.width) + 4, baselineRow: 34,
                text: "Field three alpha bravo charlie x", pointSize: 18,
                candidates: TypefaceMatcher.defaultCandidates(pointSize: 18)
            )
        )
        // The rendering is 6pt further right than the strip's text, so the face may or may not be
        // recovered; only a wrong answer would be a failure.
        if let match {
            XCTAssertEqual(match.familyName, "Georgia")
        }
    }

    func testLineTailStopsAtHardBreaksAndIsBounded() {
        XCTAssertEqual(HostLineText.tail(of: "first line\nsecond line here"), "second line here")
        XCTAssertEqual(HostLineText.tail(of: String(repeating: "a", count: 100)).count, HostLineText.maximumLength)
    }
}
