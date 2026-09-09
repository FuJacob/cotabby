import XCTest
@testable import Cotabby

final class HostBackgroundSamplerTests: XCTestCase {
    /// Builds a bitmap from a per-pixel `[red, green, blue]` closure.
    private func bitmap(width: Int, height: Int, fill: (Int, Int) -> [UInt8]) -> RGBABitmap {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                bytes += fill(column, row) + [255]
            }
        }
        return RGBABitmap(width: width, height: height, bytes: bytes)
    }

    func testTheModeIsTheBackgroundEvenWithGlyphsOnEveryRow() {
        // A blue-ish field with anti-aliased black text covering a third of the pixels in varying grays.
        let strip = bitmap(width: 30, height: 10) { column, row in
            column % 3 == 0 ? [UInt8((column + row) % 90), UInt8((column * row) % 90), UInt8(row)] : [250, 252, 255]
        }
        let color = HostBackgroundSampler.dominantColor(in: strip, rows: 0..<10)
        XCTAssertEqual(color, RGBABitmap.Pixel(red: 250 / 255, green: 252 / 255, blue: 1))
    }

    func testRowRangesAreHonoredAndClamped() {
        let strip = bitmap(width: 4, height: 4) { _, row in row < 2 ? [0, 0, 0] : [255, 255, 255] }
        XCTAssertEqual(HostBackgroundSampler.dominantColor(in: strip, rows: 0..<2), RGBABitmap.Pixel(red: 0, green: 0, blue: 0))
        XCTAssertEqual(HostBackgroundSampler.dominantColor(in: strip, rows: 2..<40), RGBABitmap.Pixel(red: 1, green: 1, blue: 1))
        XCTAssertNil(HostBackgroundSampler.dominantColor(in: strip, rows: 4..<4))
        XCTAssertNil(HostBackgroundSampler.dominantColor(in: strip, rows: 9..<12))
    }
}
