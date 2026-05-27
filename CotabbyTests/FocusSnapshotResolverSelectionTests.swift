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
}
