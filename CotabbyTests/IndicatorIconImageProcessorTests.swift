import AppKit
import XCTest
@testable import Cotabby

/// Tests for the pure image rules behind the user-customizable activation indicator icon.
final class IndicatorIconImageProcessorTests: XCTestCase {
    func test_squareIconPNGData_producesSquarePNGForValidImage() {
        let source = makeTestPNG(width: 30, height: 10)

        guard let output = IndicatorIconImageProcessor.squareIconPNGData(from: source, pixelSize: 32) else {
            return XCTFail("Expected a square icon for a valid image")
        }
        guard let representation = NSBitmapImageRep(data: output) else {
            return XCTFail("Processed output was not a decodable image")
        }

        XCTAssertEqual(representation.pixelsWide, 32)
        XCTAssertEqual(representation.pixelsHigh, 32)
    }

    func test_squareIconPNGData_returnsNilForNonImageData() {
        XCTAssertNil(IndicatorIconImageProcessor.squareIconPNGData(from: Data("not an image".utf8)))
        XCTAssertNil(IndicatorIconImageProcessor.squareIconPNGData(from: Data()))
    }

    func test_aspectFillRect_coversSquareForWideSource() {
        let rect = IndicatorIconImageProcessor.aspectFillRect(
            sourceSize: NSSize(width: 100, height: 50),
            in: NSRect(x: 0, y: 0, width: 20, height: 20)
        )

        assertRect(rect, equals: NSRect(x: -10, y: 0, width: 40, height: 20))
    }

    func test_aspectFillRect_coversSquareForTallSource() {
        let rect = IndicatorIconImageProcessor.aspectFillRect(
            sourceSize: NSSize(width: 50, height: 100),
            in: NSRect(x: 0, y: 0, width: 20, height: 20)
        )

        assertRect(rect, equals: NSRect(x: 0, y: -10, width: 20, height: 40))
    }

    func test_aspectFillRect_isIdentityForSquareSource() {
        let rect = IndicatorIconImageProcessor.aspectFillRect(
            sourceSize: NSSize(width: 10, height: 10),
            in: NSRect(x: 0, y: 0, width: 20, height: 20)
        )

        assertRect(rect, equals: NSRect(x: 0, y: 0, width: 20, height: 20))
    }

    func test_aspectFillRect_fallsBackToDestinationForEmptySource() {
        let rect = IndicatorIconImageProcessor.aspectFillRect(
            sourceSize: .zero,
            in: NSRect(x: 1, y: 2, width: 20, height: 20)
        )

        assertRect(rect, equals: NSRect(x: 1, y: 2, width: 20, height: 20))
    }

    // MARK: - Helpers

    private func assertRect(
        _ rect: NSRect,
        equals expected: NSRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(rect.origin.x, expected.origin.x, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(rect.origin.y, expected.origin.y, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(rect.width, expected.width, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(rect.height, expected.height, accuracy: 0.0001, file: file, line: line)
    }

    private func makeTestPNG(width: Int, height: Int) -> Data {
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let context = NSGraphicsContext(bitmapImageRep: representation)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return representation.representation(using: .png, properties: [:])!
    }
}
