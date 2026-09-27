import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the pure CoreGraphics (top-left origin) to AppKit (bottom-left origin) conversion.
/// The key rule: Y flips inside the display that owns the rect, never against a union of monitors,
/// so arrangements like a secondary display above or left of the primary convert correctly.
final class DisplayCoordinateConverterTests: XCTestCase {

    /// Builds a display whose CoreGraphics bounds are given directly and whose AppKit frame is
    /// supplied separately (they differ only in Y for displays not aligned with the primary).
    /// `visibleFrame` is irrelevant to conversion, so it simply mirrors the AppKit frame.
    private func display(
        appKit: CGRect,
        coreGraphics: CGRect? = nil,
        scale: CGFloat = 1
    ) -> DisplayGeometry {
        DisplayGeometry(
            appKitFrame: appKit,
            visibleFrame: appKit,
            coreGraphicsBounds: coreGraphics ?? appKit,
            backingScaleFactor: scale
        )
    }

    private lazy var primary = display(appKit: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)

    // MARK: - appKitRect(fromCoreGraphicsRect:displays:)

    func test_appKitRect_flipsWithinOwningDisplayAbovePrimary() {
        let displayAbove = display(
            appKit: CGRect(x: 0, y: 900, width: 1920, height: 1080),
            coreGraphics: CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        )

        let rect = DisplayCoordinateConverter.appKitRect(
            fromCoreGraphicsRect: CGRect(x: 120, y: -1000, width: 300, height: 20),
            displays: [primary, displayAbove]
        )

        // Local Y 80 inside the upper display: 1980 - 80 - 20 = 1880.
        XCTAssertEqual(rect, CGRect(x: 120, y: 1880, width: 300, height: 20))
    }

    func test_appKitRect_preservesNegativeXWhenRectCrossesDisplayBoundary() {
        let left = display(appKit: CGRect(x: -1280, y: 0, width: 1280, height: 720))

        let rect = DisplayCoordinateConverter.appKitRect(
            fromCoreGraphicsRect: CGRect(x: -20, y: 100, width: 80, height: 20),
            displays: [left, primary]
        )

        // Midpoint (20, 110) lies on the primary, so the flip uses its 900pt height.
        XCTAssertEqual(rect, CGRect(x: -20, y: 780, width: 80, height: 20))
    }

    func test_appKitRect_returnsNilWhenNoDisplayOwnsTheRect() {
        // A rect far outside every display (a stale AX value after a monitor was unplugged) must
        // map to nil rather than to a flipped guess against the wrong display.
        XCTAssertNil(DisplayCoordinateConverter.appKitRect(
            fromCoreGraphicsRect: CGRect(x: 5000, y: 5000, width: 10, height: 10),
            displays: [primary]
        ))
        XCTAssertNil(DisplayCoordinateConverter.appKitRect(
            fromCoreGraphicsRect: CGRect(x: 100, y: 100, width: 10, height: 10),
            displays: []
        ))
    }

    func test_appKitRect_fallsBackToLargestIntersectionWhenMidpointOutsideEveryDisplay() {
        let left = display(appKit: CGRect(x: 0, y: 0, width: 100, height: 100))
        let right = display(appKit: CGRect(x: 100, y: 0, width: 100, height: 100))

        // The rect hangs below both displays so its midpoint (90, 110) is inside neither, but it
        // overlaps the left display by 300 square points and the right by only 100. The conversion
        // must flip inside the display with the larger overlap.
        let rect = DisplayCoordinateConverter.appKitRect(
            fromCoreGraphicsRect: CGRect(x: 70, y: 90, width: 40, height: 40),
            displays: [left, right]
        )

        XCTAssertEqual(rect, CGRect(x: 70, y: -30, width: 40, height: 40))
    }

    func test_appKitRect_midpointContainmentBeatsALargerOverlap() {
        // A short display owns the midpoint (90, 0) but overlaps the rect by only 40 x 10 = 400,
        // while a tall neighbor overlaps it by 20 x 200 = 4000. Containment is checked first, so
        // the flip still happens inside the short display: 10 - (-100) - 200 = -90.
        let short = display(appKit: CGRect(x: 0, y: 0, width: 100, height: 10))
        let tall = display(appKit: CGRect(x: 100, y: -500, width: 100, height: 1000))

        let rect = DisplayCoordinateConverter.appKitRect(
            fromCoreGraphicsRect: CGRect(x: 60, y: -100, width: 60, height: 200),
            displays: [tall, short]
        )

        XCTAssertEqual(rect, CGRect(x: 60, y: -90, width: 60, height: 200))
    }

    // MARK: - appKitRectsFromPixelRect(_:displays:)

    private lazy var rightRetina = display(
        appKit: CGRect(x: 1440, y: 0, width: 1512, height: 982),
        scale: 2
    )

    func test_appKitRectsFromPixelRect_scalesRelativeToDisplayOrigin() {
        // Pixel X 3080 is 200 pixels (100 points) into the right display's 2880-pixel origin.
        let rects = DisplayCoordinateConverter.appKitRectsFromPixelRect(
            CGRect(x: 1440 * 2 + 200, y: 120, width: 80, height: 40),
            displays: [primary, rightRetina]
        )

        XCTAssertEqual(rects, [CGRect(x: 1540, y: 902, width: 40, height: 20)])
    }

    func test_appKitRectsFromPixelRect_returnsOneRectPerDisplayTheRectStraddles() {
        // Pixel 2860...2940 crosses the 2880-pixel seam, so both displays convert it, each in its
        // own frame: the primary flips against 900pt, the right display against 982pt.
        let rects = DisplayCoordinateConverter.appKitRectsFromPixelRect(
            CGRect(x: 2860, y: 100, width: 80, height: 40),
            displays: [primary, rightRetina]
        )

        XCTAssertEqual(rects, [
            CGRect(x: 1430, y: 830, width: 40, height: 20),
            CGRect(x: 1430, y: 912, width: 40, height: 20)
        ])
    }

    func test_appKitRectsFromPixelRect_isEmptyWhenNoDisplayContainsTheRect() {
        XCTAssertEqual(
            DisplayCoordinateConverter.appKitRectsFromPixelRect(
                CGRect(x: 100_000, y: 100_000, width: 10, height: 10),
                displays: [primary, rightRetina]
            ),
            []
        )
    }

    func test_appKitRectsFromPixelRect_skipsDisplaysWithZeroScaleFactor() {
        // A zero backing scale (a display mid-reconfiguration) would divide by zero; the converter
        // must skip that display and still convert against the healthy one.
        let broken = display(appKit: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 0)

        let rects = DisplayCoordinateConverter.appKitRectsFromPixelRect(
            CGRect(x: 100, y: 100, width: 80, height: 40),
            displays: [broken, primary]
        )

        XCTAssertEqual(rects, [CGRect(x: 50, y: 830, width: 40, height: 20)])
    }
}
