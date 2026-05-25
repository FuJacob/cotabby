import CoreGraphics
import XCTest
@testable import Cotabby

final class DisplayCoordinateConverterTests: XCTestCase {
    func test_appKitRect_flipsWithinOwningDisplayAbovePrimary() {
        let primary = DisplayGeometry(
            appKitFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
            coreGraphicsBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            backingScaleFactor: 2
        )
        let displayAbove = DisplayGeometry(
            appKitFrame: CGRect(x: 0, y: 900, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 900, width: 1920, height: 1055),
            coreGraphicsBounds: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
            backingScaleFactor: 1
        )

        let rect = DisplayCoordinateConverter.appKitRect(
            fromCoreGraphicsRect: CGRect(x: 120, y: -1000, width: 300, height: 20),
            displays: [primary, displayAbove]
        )

        XCTAssertEqual(rect, CGRect(x: 120, y: 1880, width: 300, height: 20))
    }

    func test_appKitRect_preservesNegativeXWhenRectCrossesDisplayBoundary() {
        let left = DisplayGeometry(
            appKitFrame: CGRect(x: -1280, y: 0, width: 1280, height: 720),
            visibleFrame: CGRect(x: -1280, y: 0, width: 1280, height: 700),
            coreGraphicsBounds: CGRect(x: -1280, y: 0, width: 1280, height: 720),
            backingScaleFactor: 1
        )
        let primary = DisplayGeometry(
            appKitFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
            coreGraphicsBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            backingScaleFactor: 2
        )

        let rect = DisplayCoordinateConverter.appKitRect(
            fromCoreGraphicsRect: CGRect(x: -20, y: 100, width: 80, height: 20),
            displays: [left, primary]
        )

        XCTAssertEqual(rect, CGRect(x: -20, y: 780, width: 80, height: 20))
    }

    func test_appKitRectsFromPixelRect_scalesRelativeToDisplayOrigin() {
        let primary = DisplayGeometry(
            appKitFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
            coreGraphicsBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            backingScaleFactor: 2
        )
        let rightRetina = DisplayGeometry(
            appKitFrame: CGRect(x: 1440, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 1440, y: 0, width: 1512, height: 957),
            coreGraphicsBounds: CGRect(x: 1440, y: 0, width: 1512, height: 982),
            backingScaleFactor: 2
        )

        let rects = DisplayCoordinateConverter.appKitRectsFromPixelRect(
            CGRect(x: 1440 * 2 + 200, y: 120, width: 80, height: 40),
            displays: [primary, rightRetina]
        )

        XCTAssertEqual(rects, [CGRect(x: 1540, y: 902, width: 40, height: 20)])
    }
}
