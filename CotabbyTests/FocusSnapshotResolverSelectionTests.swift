import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests the pure caret-geometry trust policy used by `FocusSnapshotResolver`.
///
/// These tests intentionally avoid live Accessibility objects. The regression we are guarding
/// against is not whether AX can produce a rect; it is whether Cotabby trusts a descendant rect over
/// the focused input's own usable rect.
final class FocusSnapshotResolverSelectionTests: XCTestCase {
    private let primaryRect = CGRect(x: 10, y: 20, width: 2, height: 16)
    private let deepRect = CGRect(x: 100, y: 120, width: 2, height: 16)

    func testShouldSearchDeepOnlyForWeakPrimaryGeometry() {
        XCTAssertFalse(CaretGeometrySelector.shouldSearchDeep(
            primaryRect: primaryRect,
            primaryQuality: .exact
        ))
        XCTAssertFalse(CaretGeometrySelector.shouldSearchDeep(
            primaryRect: primaryRect,
            primaryQuality: .derived
        ))
        XCTAssertTrue(CaretGeometrySelector.shouldSearchDeep(
            primaryRect: primaryRect,
            primaryQuality: .estimated
        ))
        XCTAssertTrue(CaretGeometrySelector.shouldSearchDeep(
            primaryRect: primaryRect,
            primaryQuality: nil
        ))
        XCTAssertTrue(CaretGeometrySelector.shouldSearchDeep(
            primaryRect: nil,
            primaryQuality: .derived
        ))
    }

    func testPrimaryExactWinsOverDeepExact() throws {
        let selected = try XCTUnwrap(CaretGeometrySelector.select(
            primaryRect: primaryRect,
            primaryQuality: .exact,
            primaryObservedCharWidth: 7,
            deepResult: CaretGeometryResult(rect: deepRect, quality: .exact, observedCharWidth: 4)
        ))

        XCTAssertEqual(selected.rect, primaryRect)
        XCTAssertEqual(selected.quality, .exact)
        XCTAssertEqual(selected.source, "exact primary")
        XCTAssertEqual(selected.observedCharWidth, 7)
    }

    func testPrimaryDerivedWinsOverDeepExact() throws {
        let selected = try XCTUnwrap(CaretGeometrySelector.select(
            primaryRect: primaryRect,
            primaryQuality: .derived,
            primaryObservedCharWidth: 8,
            deepResult: CaretGeometryResult(rect: deepRect, quality: .exact, observedCharWidth: 3)
        ))

        XCTAssertEqual(selected.rect, primaryRect)
        XCTAssertEqual(selected.quality, .derived)
        XCTAssertEqual(selected.source, "derived primary")
        XCTAssertEqual(selected.observedCharWidth, 8)
    }

    func testDeepExactWinsWhenPrimaryIsOnlyEstimated() throws {
        let selected = try XCTUnwrap(CaretGeometrySelector.select(
            primaryRect: primaryRect,
            primaryQuality: .estimated,
            primaryObservedCharWidth: nil,
            deepResult: CaretGeometryResult(rect: deepRect, quality: .exact, observedCharWidth: 5)
        ))

        XCTAssertEqual(selected.rect, deepRect)
        XCTAssertEqual(selected.quality, .exact)
        XCTAssertEqual(selected.source, "exact deep")
        XCTAssertEqual(selected.observedCharWidth, 5)
    }

    func testPrimaryFallbackStillWorksWithoutDeepGeometry() throws {
        let selected = try XCTUnwrap(CaretGeometrySelector.select(
            primaryRect: primaryRect,
            primaryQuality: .estimated,
            primaryObservedCharWidth: nil,
            deepResult: nil
        ))

        XCTAssertEqual(selected.rect, primaryRect)
        XCTAssertEqual(selected.quality, .estimated)
        XCTAssertEqual(selected.source, "estimated primary-fallback")
    }

    func testSelectReturnsNilWhenNeitherSourceProducedARect() {
        XCTAssertNil(CaretGeometrySelector.select(
            primaryRect: nil,
            primaryQuality: nil,
            primaryObservedCharWidth: nil,
            deepResult: nil
        ))
    }

    func testPrimarySourceDetailIsAppendedToTheSourceLabel() throws {
        // The resolver-supplied mapping detail must surface in the debug badge label so logs show
        // not just which branch won but how the caret mapped.
        let selected = try XCTUnwrap(CaretGeometrySelector.select(
            primaryRect: primaryRect,
            primaryQuality: .exact,
            primaryObservedCharWidth: nil,
            primarySourceDetail: "marker-run",
            deepResult: nil
        ))

        XCTAssertEqual(selected.source, "exact primary (marker-run)")
        XCTAssertEqual(selected.quality, .exact)
    }

    func testUnknownPrimaryQualityFallsBackToEstimatedWithUnknownLabel() throws {
        // A rect with no quality signal at all still ships (better than nothing), but it must be
        // labeled "unknown" and demoted to `.estimated` so downstream policy treats it as weak.
        let selected = try XCTUnwrap(CaretGeometrySelector.select(
            primaryRect: primaryRect,
            primaryQuality: nil,
            primaryObservedCharWidth: nil,
            deepResult: nil
        ))

        XCTAssertEqual(selected.rect, primaryRect)
        XCTAssertEqual(selected.quality, .estimated)
        XCTAssertEqual(selected.source, "unknown primary-fallback")
    }
}
