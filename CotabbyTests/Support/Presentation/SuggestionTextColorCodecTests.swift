import AppKit
import XCTest
@testable import Cotabby

/// Tests for the hex <-> color conversions behind the ghost-text color setting.
///
/// These lock the persistence contract: exactly six hex digits (no `#` prefix, unlike the settings
/// store's normalizer, which strips it before this codec ever sees the value), sRGB component math
/// in both directions, and a nil result for colors with no RGB representation.
final class SuggestionTextColorCodecConversionTests: XCTestCase {
    func test_nsColor_parsesSixDigitHexIntoSRGBComponents() throws {
        let color = try XCTUnwrap(SuggestionTextColorCodec.nsColor(fromHex: "3366FF"))

        XCTAssertEqual(color.redComponent, 0x33 / 255.0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 0x66 / 255.0, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 1.0, accuracy: 0.001)
    }

    func test_nsColor_trimsWhitespaceAndAcceptsLowercase() throws {
        let padded = try XCTUnwrap(SuggestionTextColorCodec.nsColor(fromHex: " a1b2c3 \n"))
        let canonical = try XCTUnwrap(SuggestionTextColorCodec.nsColor(fromHex: "A1B2C3"))

        XCTAssertEqual(padded.redComponent, canonical.redComponent, accuracy: 0.0001)
        XCTAssertEqual(padded.greenComponent, canonical.greenComponent, accuracy: 0.0001)
        XCTAssertEqual(padded.blueComponent, canonical.blueComponent, accuracy: 0.0001)
    }

    func test_nsColor_rejectsNilAndMalformedHex() {
        XCTAssertNil(SuggestionTextColorCodec.nsColor(fromHex: nil))
        XCTAssertNil(SuggestionTextColorCodec.nsColor(fromHex: "FFF"), "Shorthand hex is not supported")
        XCTAssertNil(SuggestionTextColorCodec.nsColor(fromHex: "1234567"), "Seven digits is not a color")
        XCTAssertNil(SuggestionTextColorCodec.nsColor(fromHex: "GGGGGG"), "Non-hex characters must be rejected")
        XCTAssertNil(
            SuggestionTextColorCodec.nsColor(fromHex: "#3366FF"),
            "The codec expects the bare six digits; prefix stripping happens upstream"
        )
    }

    func test_color_wrapsValidHexAndRejectsInvalid() {
        XCTAssertNotNil(SuggestionTextColorCodec.color(fromHex: "FF0000"))
        XCTAssertNil(SuggestionTextColorCodec.color(fromHex: "nope!!"))
        XCTAssertNil(SuggestionTextColorCodec.color(fromHex: nil))
    }

    func test_hexString_roundTripsThroughNSColor() throws {
        let color = try XCTUnwrap(SuggestionTextColorCodec.nsColor(fromHex: "1A2B3C"))

        XCTAssertEqual(SuggestionTextColorCodec.hexString(from: color), "1A2B3C")
    }

    func test_hexString_convertsOtherColorSpacesToSRGB() {
        // NSColor.white is calibrated grayscale; the codec must convert before reading components.
        XCTAssertEqual(SuggestionTextColorCodec.hexString(from: .white), "FFFFFF")
        XCTAssertEqual(SuggestionTextColorCodec.hexString(from: .black), "000000")
    }

    func test_hexString_returnsNilWhenColorHasNoRGBRepresentation() {
        // Pattern colors cannot be converted to sRGB, so persisting one must yield nil instead of
        // garbage components.
        let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 1, height: 1)))

        XCTAssertNil(SuggestionTextColorCodec.hexString(from: pattern))
    }
}
