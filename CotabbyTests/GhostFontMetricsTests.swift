import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the pure ghost-text sizing math. These lock in two behaviors: the fixed-ratio fallback
/// (unchanged from before field-style resolution) and the metric-based path that scales by the host
/// font's own glyph-box ratio so ghost text matches the field's apparent size.
final class GhostFontMetricsTests: XCTestCase {
    private let fallbackRatio: CGFloat = 0.78
    private let minimum: CGFloat = 14
    private let maximum: CGFloat = 24

    private func metrics(pointSize: CGFloat, ascender: CGFloat, descender: CGFloat) -> GhostFontMetrics.FieldFontMetrics {
        GhostFontMetrics.FieldFontMetrics(pointSize: pointSize, ascender: ascender, descender: descender)
    }

    func testFallsBackToFixedRatioWhenNoFieldMetrics() {
        let size = GhostFontMetrics.pointSize(
            caretHeight: 20,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum
        )
        // max(14, 20 * 0.78) = 15.6, under the cap.
        XCTAssertEqual(size, 15.6, accuracy: 0.0001)
    }

    func testUsesFieldFontGlyphBoxRatioWhenAvailable() {
        // Glyph box = ascender - descender = 11 - (-3) = 14, ratio = 12 / 14.
        let size = GhostFontMetrics.pointSize(
            caretHeight: 20,
            fieldMetrics: metrics(pointSize: 12, ascender: 11, descender: -3),
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum
        )
        XCTAssertEqual(size, 20 * (12.0 / 14.0), accuracy: 0.0001)
    }

    func testMetricRatioIsScaleInvariant() {
        // The same typeface reported at two sizes must yield the same ghost size, since the helper
        // uses only the ratio. This is why callers may instantiate the reference font at any size.
        let small = GhostFontMetrics.pointSize(
            caretHeight: 18,
            fieldMetrics: metrics(pointSize: 12, ascender: 11, descender: -3),
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum
        )
        let large = GhostFontMetrics.pointSize(
            caretHeight: 18,
            fieldMetrics: metrics(pointSize: 24, ascender: 22, descender: -6),
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum
        )
        XCTAssertEqual(small, large, accuracy: 0.0001)
    }

    func testAppliesMinimumFloor() {
        let size = GhostFontMetrics.pointSize(
            caretHeight: 5,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum
        )
        XCTAssertEqual(size, minimum, accuracy: 0.0001)
    }

    func testAppliesMaximumCap() {
        let size = GhostFontMetrics.pointSize(
            caretHeight: 100,
            fieldMetrics: metrics(pointSize: 12, ascender: 11, descender: -3),
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum
        )
        XCTAssertEqual(size, maximum, accuracy: 0.0001)
    }

    func testDegenerateGlyphBoxFallsBackToFixedRatio() {
        // ascender - descender <= 0 is unusable, so the fixed ratio must be used instead.
        let size = GhostFontMetrics.pointSize(
            caretHeight: 20,
            fieldMetrics: metrics(pointSize: 12, ascender: 5, descender: 5),
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum
        )
        XCTAssertEqual(size, 20 * fallbackRatio, accuracy: 0.0001)
    }

    func testNonPositivePointSizeFallsBackToFixedRatio() {
        let size = GhostFontMetrics.pointSize(
            caretHeight: 20,
            fieldMetrics: metrics(pointSize: 0, ascender: 11, descender: -3),
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum
        )
        XCTAssertEqual(size, 20 * fallbackRatio, accuracy: 0.0001)
    }
}
