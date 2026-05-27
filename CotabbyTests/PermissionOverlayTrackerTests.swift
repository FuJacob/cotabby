import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the pure overlay-transition rule that keeps the guided-permission helper from
/// flickering as window focus bounces during the granting flow.
final class PermissionOverlayTrackerTests: XCTestCase {
    private let frameA = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let frameB = CGRect(x: 140, y: 120, width: 800, height: 600)

    func test_noSettingsWindow_whileHidden_isNoOp() {
        XCTAssertEqual(
            PermissionOverlayTracker.transition(settingsFrame: nil, hasPresented: false, isVisible: false, lastFrame: nil),
            .none
        )
        // Already presented earlier but currently hidden — still a no-op, not a redundant hide.
        XCTAssertEqual(
            PermissionOverlayTracker.transition(settingsFrame: nil, hasPresented: true, isVisible: false, lastFrame: nil),
            .none
        )
    }

    func test_noSettingsWindow_whileVisible_hides() {
        XCTAssertEqual(
            PermissionOverlayTracker.transition(settingsFrame: nil, hasPresented: true, isVisible: true, lastFrame: frameA),
            .hide
        )
    }

    func test_firstAppearance_presents() {
        XCTAssertEqual(
            PermissionOverlayTracker.transition(settingsFrame: frameA, hasPresented: false, isVisible: false, lastFrame: nil),
            .present
        )
    }

    func test_alreadyParkedAtSameFrame_isNoOp() {
        XCTAssertEqual(
            PermissionOverlayTracker.transition(settingsFrame: frameA, hasPresented: true, isVisible: true, lastFrame: frameA),
            .none
        )
    }

    func test_settingsWindowMoved_repositions() {
        XCTAssertEqual(
            PermissionOverlayTracker.transition(settingsFrame: frameB, hasPresented: true, isVisible: true, lastFrame: frameA),
            .reposition
        )
    }

    func test_reshowAfterHide_repositionsWithoutReanimating() {
        XCTAssertEqual(
            PermissionOverlayTracker.transition(settingsFrame: frameA, hasPresented: true, isVisible: false, lastFrame: nil),
            .reposition
        )
    }
}
