import AppKit
import XCTest
@testable import Cotabby

/// Pins how the user's bold/italic suggestion style is turned into a face: the host family's own
/// bold and italic members when they exist, a system bold or a synthetic oblique when they do not,
/// and the host font itself, untouched, when no style is asked for.
final class GhostFontStylerTests: XCTestCase {
    private let helvetica = NSFont(name: "Helvetica", size: 15)!

    func test_noStyleReturnsTheHostFontItself() {
        XCTAssertEqual(GhostFontStyler.styled(helvetica, bold: false, italic: false), helvetica)
    }

    func test_boldUsesTheHostFamilysBoldFaceAtTheSameSize() {
        let bold = GhostFontStyler.styled(helvetica, bold: true, italic: false)

        XCTAssertTrue(GhostFontStyler.isBold(bold))
        XCTAssertFalse(GhostFontStyler.isItalic(bold))
        XCTAssertEqual(bold.familyName, "Helvetica")
        XCTAssertEqual(bold.pointSize, 15)
    }

    func test_italicUsesTheHostFamilysItalicFaceAtTheSameSize() {
        let italic = GhostFontStyler.styled(helvetica, bold: false, italic: true)

        XCTAssertTrue(italic.fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertFalse(GhostFontStyler.isBold(italic))
        XCTAssertEqual(italic.familyName, "Helvetica")
        XCTAssertEqual(italic.pointSize, 15)
    }

    func test_boldAndItalicCombine() {
        let both = GhostFontStyler.styled(helvetica, bold: true, italic: true)

        XCTAssertTrue(GhostFontStyler.isBold(both))
        XCTAssertTrue(GhostFontStyler.isItalic(both))
        XCTAssertEqual(both.familyName, "Helvetica")
    }

    func test_theSystemFaceStylesLikeANamedFamily() {
        let system = NSFont.systemFont(ofSize: 13)
        let both = GhostFontStyler.styled(system, bold: true, italic: true)

        XCTAssertTrue(GhostFontStyler.isBold(both))
        XCTAssertTrue(GhostFontStyler.isItalic(both))
        XCTAssertEqual(both.pointSize, 13)
    }

    /// Zapfino ships one face. Asking for bold falls back to the system bold at the host's size, so
    /// the setting still shows; asking for italic slants Zapfino itself.
    func test_aFamilyWithoutTheStyleStillGetsAVisibleStyle() throws {
        let single = try XCTUnwrap(NSFont(name: "Zapfino", size: 14))

        let bold = GhostFontStyler.styled(single, bold: true, italic: false)
        XCTAssertTrue(GhostFontStyler.isBold(bold))
        XCTAssertEqual(bold.pointSize, 14)

        let italic = GhostFontStyler.styled(single, bold: false, italic: true)
        XCTAssertTrue(GhostFontStyler.isItalic(italic))
        XCTAssertEqual(italic.fontName, single.fontName, "a synthetic oblique keeps the face")
        XCTAssertEqual(italic.pointSize, 14, accuracy: 0.01)
    }
}
