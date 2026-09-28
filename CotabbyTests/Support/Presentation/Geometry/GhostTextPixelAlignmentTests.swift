import AppKit
import XCTest
@testable import Cotabby

/// Renders real TextKit text and the ghost renderer into the same Retina-scale bitmap and compares
/// where the ink lands. This is the definition of "ghost text renders identically to native text"
/// for every AppKit host: the ghost glyphs for " jumps" must occupy the pixels TextKit itself uses
/// for " jumps" once the word is real. No screenshots, no permissions, deterministic.
///
/// The reference is an `NSTextView` showing `prefix + ghost`; the candidate is an `NSTextView`
/// showing only `prefix` with `GhostTextPanelView` painting `ghost` at the caret box TextKit reports
/// for the end of `prefix`. Ink bounding boxes and centroids of the ghost region must agree to
/// within one device pixel.
@MainActor
final class GhostTextPixelAlignmentTests: XCTestCase {
    private static let scale: CGFloat = 2
    private static let prefix = "The quick brown fox"
    private static let ghost = " jumps over"

    private struct InkStats {
        let minX: Int
        let maxX: Int
        let minY: Int
        let maxY: Int
        let centroidX: Double
        let centroidY: Double
        let count: Int
    }

    private struct Rendered {
        let reference: NSBitmapImageRep
        let candidate: NSBitmapImageRep
        let regionStartX: Int
    }

    func testMenlo14MatchesTextKit() throws { try assertAligned(font: NSFont(name: "Menlo-Regular", size: 14)!) }
    func testHelvetica12MatchesTextKit() throws { try assertAligned(font: NSFont(name: "Helvetica", size: 12)!) }
    func testHelvetica16MatchesTextKit() throws { try assertAligned(font: NSFont(name: "Helvetica", size: 16)!) }
    func testGeorgia18MatchesTextKit() throws { try assertAligned(font: NSFont(name: "Georgia", size: 18)!) }
    func testTimes12MatchesTextKit() throws { try assertAligned(font: NSFont(name: "Times-Roman", size: 12)!) }
    func testSystem13MatchesTextKit() throws { try assertAligned(font: NSFont.systemFont(ofSize: 13)) }
    func testSystem15MatchesTextKit() throws { try assertAligned(font: NSFont.systemFont(ofSize: 15)) }
    func testSystem11MatchesTextKit() throws { try assertAligned(font: NSFont.systemFont(ofSize: 11)) }
    func testMonospacedSystem12MatchesTextKit() throws { try assertAligned(font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)) }

    func testTypeThroughLeavesRemainingGlyphsOnIdenticalPixels() throws {
        let font = NSFont(name: "Menlo-Regular", size: 14)!
        let (caret, bounds) = try caretGeometry(prefix: Self.prefix, font: font)
        let full = try XCTUnwrap(makeLayout(fullText: Self.ghost, consumed: 0, caret: caret, font: font))
        let advanced = try XCTUnwrap(makeLayout(fullText: Self.ghost, consumed: 6, caret: caret, font: font))
        let before = renderGhost(full, bounds: bounds)
        let after = renderGhost(advanced, bounds: bounds)
        // Everything right of the consumed " jumps" must be byte-identical.
        let splitX = Int(((advanced.rows[0].penX) * Self.scale).rounded(.down))
        let (beforeInk, afterInk) = (try XCTUnwrap(inkStats(before, fromX: splitX)), try XCTUnwrap(inkStats(after, fromX: splitX)))
        XCTAssertEqual(beforeInk.minX, afterInk.minX)
        XCTAssertEqual(beforeInk.maxX, afterInk.maxX)
        XCTAssertEqual(beforeInk.minY, afterInk.minY)
        XCTAssertEqual(beforeInk.maxY, afterInk.maxY)
        XCTAssertEqual(beforeInk.centroidX, afterInk.centroidX, accuracy: 0.01)
        XCTAssertEqual(beforeInk.centroidY, afterInk.centroidY, accuracy: 0.01)
    }

    // MARK: - Harness

    private func assertAligned(font: NSFont, file: StaticString = #filePath, line: UInt = #line) throws {
        let rendered = try render(font: font)
        let reference = try XCTUnwrap(inkStats(rendered.reference, fromX: rendered.regionStartX), "no reference ink", file: file, line: line)
        let candidate = try XCTUnwrap(inkStats(rendered.candidate, fromX: rendered.regionStartX), "no ghost ink", file: file, line: line)
        let detail = "\(font.fontName) \(font.pointSize): ref x[\(reference.minX),\(reference.maxX)] y[\(reference.minY),\(reference.maxY)] "
            + "c(\(reference.centroidX),\(reference.centroidY)) vs ghost x[\(candidate.minX),\(candidate.maxX)] "
            + "y[\(candidate.minY),\(candidate.maxY)] c(\(candidate.centroidX),\(candidate.centroidY))"
        XCTAssertLessThanOrEqual(abs(reference.minX - candidate.minX), 1, detail, file: file, line: line)
        XCTAssertLessThanOrEqual(abs(reference.maxX - candidate.maxX), 1, detail, file: file, line: line)
        XCTAssertLessThanOrEqual(abs(reference.minY - candidate.minY), 1, detail, file: file, line: line)
        XCTAssertLessThanOrEqual(abs(reference.maxY - candidate.maxY), 1, detail, file: file, line: line)
        XCTAssertEqual(reference.centroidX, candidate.centroidX, accuracy: 0.5, detail, file: file, line: line)
        XCTAssertEqual(reference.centroidY, candidate.centroidY, accuracy: 0.5, detail, file: file, line: line)
    }

    private func render(font: NSFont) throws -> Rendered {
        let (caret, bounds) = try caretGeometry(prefix: Self.prefix, font: font)
        let reference = renderTextView(text: Self.prefix + Self.ghost, font: font, bounds: bounds)
        let layout = try XCTUnwrap(makeLayout(fullText: Self.ghost, consumed: 0, caret: caret, font: font))
        let candidate = renderTextView(text: Self.prefix, font: font, bounds: bounds)
        let ghostRep = renderGhost(layout, bounds: bounds)
        composite(ghostRep, onto: candidate)
        return Rendered(reference: reference, candidate: candidate, regionStartX: Int((caret.minX * Self.scale).rounded(.down)) + 1)
    }

    private func makeTextView(text: String, font: NSFont, bounds: CGRect) -> NSTextView {
        let textView = NSTextView(frame: bounds)
        textView.string = text
        textView.font = font
        textView.textColor = .black
        textView.backgroundColor = .white
        textView.isEditable = false
        textView.textContainerInset = .zero
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        return textView
    }

    /// The caret box TextKit reports at the end of `prefix`: the trailing edge of the last glyph and
    /// its line fragment, converted from the text view's flipped coordinates to bottom-left Cocoa.
    private func caretGeometry(prefix: String, font: NSFont) throws -> (CGRect, CGRect) {
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 80)
        let textView = makeTextView(text: prefix, font: font, bounds: bounds)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        let glyphCount = layoutManager.numberOfGlyphs
        let lastGlyph = glyphCount - 1
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: lastGlyph, length: 1), in: container)
        let origin = textView.textContainerOrigin
        let caretFlippedTop = fragment.minY + origin.y
        let caretX = glyphRect.maxX + origin.x
        let caret = CGRect(x: caretX, y: bounds.height - caretFlippedTop - fragment.height, width: 2, height: fragment.height)
        return (caret, bounds)
    }

    private func makeLayout(fullText: String, consumed: Int, caret: CGRect, font: NSFont) -> GhostTextLayout? {
        let baseline = GhostBaselinePolicy.baselineOffsetFromTop(font: font, boxHeight: caret.height, renderer: .textKit)
        return GhostTextLayout.make(
            GhostTextLayout.Input(
                fullText: fullText,
                consumedUTF16: consumed,
                font: font,
                anchorTopLeft: CGPoint(x: caret.minX, y: caret.maxY),
                boxHeight: caret.height,
                baselineOffsetFromTop: baseline
            )
        )
    }

    private func makeRep(bounds: CGRect) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * Self.scale),
            pixelsHigh: Int(bounds.height * Self.scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = bounds.size
        return rep
    }

    private func renderTextView(text: String, font: NSFont, bounds: CGRect) -> NSBitmapImageRep {
        let textView = makeTextView(text: text, font: font, bounds: bounds)
        let rep = makeRep(bounds: bounds)
        textView.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    private func renderGhost(_ layout: GhostTextLayout, bounds: CGRect) -> NSBitmapImageRep {
        let view = GhostTextPanelView(frame: bounds)
        view.content = GhostTextPanelView.Content(
            layout: layout,
            textColor: .black,
            keycapLabel: nil,
            panelOrigin: .zero,
            isDarkAppearance: false
        )
        let rep = makeRep(bounds: bounds)
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    /// Source-over composite of the ghost's opaque ink onto the candidate text-view bitmap.
    private func composite(_ ghost: NSBitmapImageRep, onto target: NSBitmapImageRep) {
        for row in 0..<ghost.pixelsHigh {
            for column in 0..<ghost.pixelsWide {
                let ink = ghost.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) ?? .clear
                let alpha = ink.alphaComponent
                guard alpha > 0 else { continue }
                let base = target.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) ?? .white
                let mixed = NSColor(
                    deviceRed: base.redComponent * (1 - alpha) + ink.redComponent * alpha,
                    green: base.greenComponent * (1 - alpha) + ink.greenComponent * alpha,
                    blue: base.blueComponent * (1 - alpha) + ink.blueComponent * alpha,
                    alpha: 1
                )
                target.setColor(mixed, atX: column, y: row)
            }
        }
    }

    /// Bounding box and centroid of dark pixels at or right of `fromX` (device pixels). Pixels are
    /// weighted by darkness so anti-aliased edges contribute proportionally.
    private func inkStats(_ rep: NSBitmapImageRep, fromX: Int) -> InkStats? {
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        var weightedX = 0.0, weightedY = 0.0, weight = 0.0, count = 0
        for row in 0..<rep.pixelsHigh {
            for column in max(0, fromX)..<rep.pixelsWide {
                guard let color = rep.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else { continue }
                let darkness = (1 - (0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent))
                    * color.alphaComponent
                guard darkness > 0.25 else { continue }
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
                weightedX += Double(column) * darkness
                weightedY += Double(row) * darkness
                weight += darkness
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return InkStats(minX: minX, maxX: maxX, minY: minY, maxY: maxY, centroidX: weightedX / weight, centroidY: weightedY / weight, count: count)
    }
}
