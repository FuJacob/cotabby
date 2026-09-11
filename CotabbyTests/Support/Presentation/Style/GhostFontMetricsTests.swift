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

    func testDefaultMultiplierLeavesAutoSizeUnchanged() {
        // Omitting the multiplier must reproduce the pre-feature size exactly, so existing callers and
        // the out-of-box default see no change. max(14, 20 * 0.78) = 15.6.
        let size = GhostFontMetrics.pointSize(
            caretHeight: 20,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum
        )
        XCTAssertEqual(size, 15.6, accuracy: 0.0001)
    }

    func testSizeMultiplierScalesResolvedSizeBetweenTheBounds() {
        // Inside [minimum, maximum] the multiplier scales the auto-approximated 15.6 in both
        // directions. The floor is lowered to 10 so the 0.7x result (10.92) stays within it; at the
        // fixture's 14pt floor it would clamp, which is the absolute-bound behavior pinned below.
        let smaller = GhostFontMetrics.pointSize(
            caretHeight: 20,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: 10,
            maximum: maximum,
            sizeMultiplier: 0.7
        )
        XCTAssertEqual(smaller, 15.6 * 0.7, accuracy: 0.0001)

        let larger = GhostFontMetrics.pointSize(
            caretHeight: 20,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: 10,
            maximum: maximum,
            sizeMultiplier: 1.3
        )
        XCTAssertEqual(larger, 15.6 * 1.3, accuracy: 0.0001)
    }

    func testSizeMultiplierAtTheFloorStaysAtTheFloor() {
        // The multiplier scales before the clamp, so the user's floor is absolute: a field already
        // auto-sizing onto the 14pt floor does not shrink below it (5 * 0.78 * 0.8 = 3.12 -> 14).
        // Lowering "Smallest Ghost Text" is how a user asks for smaller text than that.
        let size = GhostFontMetrics.pointSize(
            caretHeight: 5,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum,
            sizeMultiplier: 0.8
        )
        XCTAssertEqual(size, minimum, accuracy: 0.0001)
    }

    func testSizeMultiplierRespectsAbsoluteFloor() {
        // `absoluteMinimumPointSize` is the backstop beneath the user's floor, so it only binds when
        // that floor is set below it. With a floor of 1: 5 * 0.78 * 0.5 = 1.95, clamped up to 9.
        let size = GhostFontMetrics.pointSize(
            caretHeight: 5,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: 1,
            maximum: maximum,
            sizeMultiplier: 0.5
        )
        XCTAssertEqual(size, GhostFontMetrics.absoluteMinimumPointSize, accuracy: 0.0001)
    }

    // MARK: - Synthetic caret height (AXFrame fallback hosts such as Microsoft Word)

    /// The exact constant `AXTextGeometryResolver.estimatedCaretRect` fabricates when AX exposes only
    /// a field frame: `ceil(systemFont(15).ascender - descender + leading)`. It is the same number in
    /// every such host, which is precisely why it must not drive font size.
    private let syntheticCaretHeight: CGFloat = 18

    func testSyntheticCaretPrefersHostReportedPointSize() {
        // Word at 161% zoom renders 16pt Aptos at roughly 26pt on screen. Whatever the host reports,
        // the fabricated 18pt caret must not be what sizing is derived from.
        let size = GhostFontMetrics.pointSize(
            caretHeight: syntheticCaretHeight,
            caretHeightIsSynthetic: true,
            fieldMetrics: metrics(pointSize: 26, ascender: 24.4, descender: -7.3),
            hostReportedPointSize: 26,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: 16,
            syntheticCaretMaximum: 32
        )
        XCTAssertEqual(size, 26, accuracy: 0.0001)
    }

    func testSyntheticCaretRegressionAgainstFabricatedHeight() {
        // Locks in the actual bug: deriving from the synthetic height pinned ghost text at
        // 18 * 0.78 = 14.04pt regardless of host size. The new path must not return that.
        let buggy = GhostFontMetrics.pointSize(
            caretHeight: syntheticCaretHeight,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: 16
        )
        XCTAssertEqual(buggy, 14.04, accuracy: 0.0001)

        let fixed = GhostFontMetrics.pointSize(
            caretHeight: syntheticCaretHeight,
            caretHeightIsSynthetic: true,
            fieldMetrics: nil,
            hostReportedPointSize: 26,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: 16,
            syntheticCaretMaximum: 32
        )
        XCTAssertEqual(fixed, 26, accuracy: 0.0001)
        XCTAssertGreaterThan(fixed, buggy)
    }

    func testSyntheticCaretUsesReportedSizeEvenWhenTypefaceFailedToLoad() {
        // Word's Aptos is bundled privately, so `NSFont(name:)` can fail while the reported point
        // size is still perfectly good. A nil `fieldMetrics` must not discard that size.
        let size = GhostFontMetrics.pointSize(
            caretHeight: syntheticCaretHeight,
            caretHeightIsSynthetic: true,
            fieldMetrics: nil,
            hostReportedPointSize: 20,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: 16,
            syntheticCaretMaximum: 32
        )
        XCTAssertEqual(size, 20, accuracy: 0.0001)
    }

    func testSyntheticCaretUsesLooserCeilingThanCaretDerivedCap() {
        // A host-reported size is not a rect estimate, so the tight estimated-quality cap (16) must
        // not apply to it; only the looser synthetic ceiling bounds it.
        let size = GhostFontMetrics.pointSize(
            caretHeight: syntheticCaretHeight,
            caretHeightIsSynthetic: true,
            fieldMetrics: nil,
            hostReportedPointSize: 200,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: 16,
            syntheticCaretMaximum: 32
        )
        XCTAssertEqual(size, 32, accuracy: 0.0001)
    }

    func testSyntheticCaretWithoutReportedSizeKeepsCaretDerivedBehavior() {
        // No host size means the fabricated height is all we have; behavior must be unchanged.
        let size = GhostFontMetrics.pointSize(
            caretHeight: syntheticCaretHeight,
            caretHeightIsSynthetic: true,
            fieldMetrics: nil,
            hostReportedPointSize: nil,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: 16,
            syntheticCaretMaximum: 32
        )
        XCTAssertEqual(size, syntheticCaretHeight * fallbackRatio, accuracy: 0.0001)
    }

    func testNonSyntheticCaretIgnoresHostReportedPointSize() {
        // A measured caret height is real information and must keep winning: hosts report sizes in
        // document points, which are wrong under zoom, whereas a measured caret is already on-screen.
        let size = GhostFontMetrics.pointSize(
            caretHeight: 20,
            caretHeightIsSynthetic: false,
            fieldMetrics: nil,
            hostReportedPointSize: 26,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: maximum,
            syntheticCaretMaximum: 32
        )
        XCTAssertEqual(size, 20 * fallbackRatio, accuracy: 0.0001)
    }

    func testSyntheticCaretWithNonPositiveReportedSizeFallsBack() {
        let size = GhostFontMetrics.pointSize(
            caretHeight: syntheticCaretHeight,
            caretHeightIsSynthetic: true,
            fieldMetrics: nil,
            hostReportedPointSize: 0,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: 16,
            syntheticCaretMaximum: 32
        )
        XCTAssertEqual(size, syntheticCaretHeight * fallbackRatio, accuracy: 0.0001)
    }

    func testSizeMultiplierStillAppliesOnSyntheticCaretPath() {
        let size = GhostFontMetrics.pointSize(
            caretHeight: syntheticCaretHeight,
            caretHeightIsSynthetic: true,
            fieldMetrics: nil,
            hostReportedPointSize: 20,
            fallbackRatio: fallbackRatio,
            minimum: minimum,
            maximum: 16,
            syntheticCaretMaximum: 32,
            sizeMultiplier: 1.2
        )
        XCTAssertEqual(size, 24, accuracy: 0.0001)
    }

    // MARK: - Zoomed hosts

    /// Regression guard for a removed "distrust" heuristic. It compared the measured caret against
    /// the glyph box implied by the host's *reported* point size — but the caret is in screen units
    /// and the report is in document units, so zoom alone could trip it. Microsoft Word at 164%
    /// reports 12pt against a 23pt caret; the correct answer is the font's own ratio applied to the
    /// caret (23 * 0.8449 = 19.43, matching the 19.68pt the host actually renders), not a fallback.
    func testZoomedHostKeepsTheFontsOwnRatio() {
        // Academy Engraved LET: pointSize / (ascender - descender) = 0.8449.
        let academy = metrics(pointSize: 12, ascender: 10.0, descender: -4.2059)
        let size = GhostFontMetrics.pointSize(
            caretHeight: 23,
            fieldMetrics: academy,
            fallbackRatio: fallbackRatio,
            minimum: 11,
            maximum: 32
        )
        XCTAssertEqual(size, 23 * (12.0 / 14.2059), accuracy: 0.01)
        // The fallback ratio would have produced 17.94 — visibly small against 19.68pt host text.
        XCTAssertGreaterThan(size, 23 * fallbackRatio)
    }

    func testSameFontAtDifferentZoomsScalesLinearly() {
        // The ratio is scale-invariant, so doubling the caret must double the ghost size. This is
        // what makes zoom handling free: the caret already carries it.
        let font = metrics(pointSize: 12, ascender: 10.0, descender: -4.2059)
        let small = GhostFontMetrics.pointSize(
            caretHeight: 14.2059, fieldMetrics: font,
            fallbackRatio: fallbackRatio, minimum: 1, maximum: 100
        )
        let large = GhostFontMetrics.pointSize(
            caretHeight: 28.4118, fieldMetrics: font,
            fallbackRatio: fallbackRatio, minimum: 1, maximum: 100
        )
        XCTAssertEqual(small, 12, accuracy: 0.01)
        XCTAssertEqual(large, 24, accuracy: 0.01)
    }

    // MARK: - The user's bounds are absolute

    /// "Smallest Ghost Text" and "Largest Ghost Text" are user-facing settings, so a size multiplier
    /// must not carry the result past them. Clamping before the multiplier let 1.3x render above the
    /// stated ceiling and 0.7x below the stated floor.
    func testSizeMultiplierCannotExceedTheCeiling() {
        let size = GhostFontMetrics.pointSize(
            caretHeight: 60,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: 11,
            maximum: 48,
            sizeMultiplier: 1.3
        )
        XCTAssertEqual(size, 48, accuracy: 0.0001)
    }

    func testSizeMultiplierCannotFallBelowTheFloor() {
        let size = GhostFontMetrics.pointSize(
            caretHeight: 14,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: 11,
            maximum: 48,
            sizeMultiplier: 0.7
        )
        XCTAssertEqual(size, 11, accuracy: 0.0001)
    }

    func testSizeMultiplierStillScalesBetweenTheBounds() {
        // Away from the rails the knob must still do its job: 20 * 0.78 * 1.2.
        let size = GhostFontMetrics.pointSize(
            caretHeight: 20,
            fieldMetrics: nil,
            fallbackRatio: fallbackRatio,
            minimum: 11,
            maximum: 48,
            sizeMultiplier: 1.2
        )
        XCTAssertEqual(size, 20 * fallbackRatio * 1.2, accuracy: 0.0001)
    }
}
