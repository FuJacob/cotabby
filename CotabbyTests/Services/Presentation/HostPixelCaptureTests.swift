import XCTest
@testable import Cotabby

@MainActor
final class HostPixelCaptureTests: XCTestCase {
    /// A region edge on a fractional device pixel makes ScreenCaptureKit resample the whole image,
    /// so every requested region is grown outward to the pixel grid.
    func test_captureRectsAreSnappedOutwardToWholePixels() {
        let snapped = HostPixelCapture.snappedToPixels(CGRect(x: 279, y: 915.5, width: 227.75, height: 22), scale: 2)
        XCTAssertEqual(snapped.minX, 279); XCTAssertEqual(snapped.minY, 915.5)
        XCTAssertEqual(snapped.maxX, 507); XCTAssertEqual(snapped.maxY, 937.5)
        let odd = HostPixelCapture.snappedToPixels(CGRect(x: 10.3, y: 4.7, width: 10.1, height: 3.1), scale: 2)
        XCTAssertEqual(odd.minX, 10); XCTAssertEqual(odd.maxX, 20.5); XCTAssertEqual(odd.minY, 4.5); XCTAssertEqual(odd.maxY, 8)
    }
}
