import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the pure overlay-transition rule that keeps the guided-permission helper from
/// flickering as window focus bounces during the granting flow.
final class PermissionOverlayTrackerTests: XCTestCase {
    private let frameA = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let frameB = CGRect(x: 140, y: 120, width: 800, height: 600)

    private func assertTransition(
        settingsFrame: CGRect?,
        from phase: PermissionOverlayPhase,
        is expectedTransition: PermissionOverlayTracker.Transition,
        to expectedPhase: PermissionOverlayPhase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = PermissionOverlayTracker.transition(settingsFrame: settingsFrame, phase: phase)
        XCTAssertEqual(result.transition, expectedTransition, file: file, line: line)
        XCTAssertEqual(result.next, expectedPhase, file: file, line: line)
    }

    func test_noSettingsWindow_beforeFirstAppearance_isNoOp() {
        assertTransition(settingsFrame: nil, from: .notPresented, is: .none, to: .notPresented)
    }

    func test_noSettingsWindow_whileHidden_isNoOpNotARedundantHide() {
        assertTransition(settingsFrame: nil, from: .hidden, is: .none, to: .hidden)
    }

    func test_noSettingsWindow_whileVisible_hides() {
        assertTransition(settingsFrame: nil, from: .visible(at: frameA), is: .hide, to: .hidden)
    }

    func test_firstAppearance_presentsAtTheSettingsFrame() {
        assertTransition(settingsFrame: frameA, from: .notPresented, is: .present, to: .visible(at: frameA))
    }

    func test_alreadyParkedAtSameFrame_isNoOp() {
        assertTransition(settingsFrame: frameA, from: .visible(at: frameA), is: .none, to: .visible(at: frameA))
    }

    func test_settingsWindowMoved_repositionsAndRemembersTheNewFrame() {
        assertTransition(settingsFrame: frameB, from: .visible(at: frameA), is: .reposition, to: .visible(at: frameB))
    }

    func test_reshowAfterHide_repositionsWithoutReanimating() {
        assertTransition(settingsFrame: frameA, from: .hidden, is: .reposition, to: .visible(at: frameA))
    }

    func test_aFullGrantingFlowAnimatesOnlyOnce() {
        // Settings opens, the macOS permission dialog takes focus, Settings comes back moved.
        var phase = PermissionOverlayPhase.notPresented
        var transitions: [PermissionOverlayTracker.Transition] = []
        for frame in [frameA, frameA, nil, nil, frameB, frameB] {
            let result = PermissionOverlayTracker.transition(settingsFrame: frame, phase: phase)
            transitions.append(result.transition)
            phase = result.next
        }

        XCTAssertEqual(transitions, [.present, .none, .hide, .none, .reposition, .none])
        XCTAssertEqual(phase, .visible(at: frameB))
    }
}
