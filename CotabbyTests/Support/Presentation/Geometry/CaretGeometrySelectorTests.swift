import CoreGraphics
import XCTest
@testable import Cotabby

/// Covers the `CaretGeometrySelector` branches that the resolver-level selection tests in
/// `FocusSnapshotResolverSelectionTests` do not: the deep result's own labeling and pass-through
/// measurements, a missing primary rect, `.layoutEstimated` primaries, and label formatting.
final class CaretGeometrySelectorTests: XCTestCase {
    private let primaryRect = CGRect(x: 10, y: 20, width: 2, height: 16)
    private let deepRect = CGRect(x: 100, y: 120, width: 2, height: 16)
    private let primaryEdges = ObservedContentEdges(leftX: 8, topY: 40, isRunMeasured: true)
    private let deepEdges = ObservedContentEdges(leftX: 96, topY: nil)

    // MARK: - shouldSearchDeep

    func test_shouldSearchDeep_demotedPrimaryNeverSearchesEvenWithoutARect() {
        // The allow-flag guard runs before the missing-rect check: a resolver that already walked
        // the descendants must not trigger a second walk just because it produced nothing.
        XCTAssertFalse(CaretGeometrySelector.shouldSearchDeep(
            primaryRect: nil,
            primaryQuality: nil,
            primaryAllowsDeepSearch: false
        ))
    }

    func test_shouldSearchDeep_layoutEstimatedPrimaryIsTreatedAsWeak() {
        XCTAssertTrue(CaretGeometrySelector.shouldSearchDeep(
            primaryRect: primaryRect,
            primaryQuality: .layoutEstimated
        ))
    }

    // MARK: - select

    func test_select_deepResultIsUsedWhenThePrimaryHasNoRect() throws {
        // Even an `.exact` label on the primary cannot win without a rect to ship.
        let selected = try XCTUnwrap(CaretGeometrySelector.select(
            primaryRect: nil,
            primaryQuality: .exact,
            primaryObservedCharWidth: 7,
            primaryObservedContentEdges: primaryEdges,
            deepResult: CaretGeometryResult(
                rect: deepRect,
                quality: .derived,
                observedCharWidth: 6,
                observedContentEdges: deepEdges,
                sourceDetail: "runs"
            )
        ))

        XCTAssertEqual(selected, CaretGeometrySelector.Selected(
            rect: deepRect,
            source: "derived deep (runs)",
            quality: .derived,
            observedCharWidth: 6,
            observedContentEdges: deepEdges,
            sourceDetail: "runs"
        ))
    }

    func test_select_primaryWinnersCarryThePrimaryMeasurementsNotTheDeepOnes() throws {
        for quality in [CaretGeometryQuality.exact, .derived] {
            let selected = try XCTUnwrap(CaretGeometrySelector.select(
                primaryRect: primaryRect,
                primaryQuality: quality,
                primaryObservedCharWidth: 7,
                primaryObservedContentEdges: primaryEdges,
                deepResult: CaretGeometryResult(rect: deepRect, quality: .exact, observedCharWidth: 4, observedContentEdges: deepEdges)
            ))

            XCTAssertEqual(selected.rect, primaryRect, "\(quality)")
            XCTAssertEqual(selected.observedCharWidth, 7, "\(quality)")
            XCTAssertEqual(selected.observedContentEdges, primaryEdges, "\(quality)")
        }
    }

    func test_select_layoutEstimatedPrimaryYieldsToDeepAndOtherwiseFallsBackWithItsOwnLabel() throws {
        let toDeep = try XCTUnwrap(CaretGeometrySelector.select(
            primaryRect: primaryRect,
            primaryQuality: .layoutEstimated,
            primaryObservedCharWidth: nil,
            deepResult: CaretGeometryResult(rect: deepRect, quality: .estimated)
        ))
        XCTAssertEqual(toDeep.rect, deepRect)
        XCTAssertEqual(toDeep.source, "estimated deep")

        let fallback = try XCTUnwrap(CaretGeometrySelector.select(
            primaryRect: primaryRect,
            primaryQuality: .layoutEstimated,
            primaryObservedCharWidth: 5,
            primaryObservedContentEdges: primaryEdges,
            primarySourceDetail: "layout",
            deepResult: nil
        ))
        XCTAssertEqual(fallback, CaretGeometrySelector.Selected(
            rect: primaryRect,
            source: "layout-estimated primary-fallback (layout)",
            quality: .layoutEstimated,
            observedCharWidth: 5,
            observedContentEdges: primaryEdges,
            sourceDetail: "layout"
        ))
    }

    func test_select_emptySourceDetailIsNotAppended() throws {
        let primary = try XCTUnwrap(CaretGeometrySelector.select(
            primaryRect: primaryRect,
            primaryQuality: .derived,
            primaryObservedCharWidth: nil,
            primarySourceDetail: "",
            deepResult: nil
        ))
        XCTAssertEqual(primary.source, "derived primary")

        let deep = try XCTUnwrap(CaretGeometrySelector.select(
            primaryRect: nil,
            primaryQuality: nil,
            primaryObservedCharWidth: nil,
            deepResult: CaretGeometryResult(rect: deepRect, quality: .exact, sourceDetail: "")
        ))
        XCTAssertEqual(deep.source, "exact deep")
    }
}
