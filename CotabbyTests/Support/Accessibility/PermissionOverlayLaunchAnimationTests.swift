import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the guided-permission overlay's fly-in: where it starts, where it lands, and that a
/// System Settings window that moves mid-flight still ends up under the overlay.
final class PermissionOverlayLaunchAnimationTests: XCTestCase {
    private let source = CGRect(x: 40, y: 500, width: 200, height: 44)
    private let target = CGRect(x: 600, y: 120, width: 540, height: 112)

    private func makeAnimation() -> PermissionOverlayLaunchAnimation {
        PermissionOverlayLaunchAnimation(startTime: 10, fromFrame: source, toFrame: target)
    }

    private func inFlight(
        _ step: PermissionOverlayLaunchAnimation.Step,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (alpha: CGFloat, frame: CGRect)? {
        guard case .inFlight(let alpha, let frame) = step else {
            XCTFail("Expected an in-flight step, got \(step)", file: file, line: line)
            return nil
        }
        return (alpha, frame)
    }

    func test_startsAtTheSourceFrameAndInitialAlpha() throws {
        let start = try XCTUnwrap(inFlight(makeAnimation().step(at: 10)))

        XCTAssertEqual(start.alpha, PermissionOverlayLaunchAnimation.initialAlpha, accuracy: 1e-9)
        XCTAssertEqual(start.frame.origin.x, source.origin.x, accuracy: 1e-6)
        XCTAssertEqual(start.frame.origin.y, source.origin.y, accuracy: 1e-6)
        XCTAssertEqual(start.frame.size.width, source.size.width, accuracy: 1e-6)
        XCTAssertEqual(start.frame.size.height, source.size.height, accuracy: 1e-6)
    }

    func test_aClockReadingBeforeTheStartIsTreatedAsTheStart() throws {
        let early = try XCTUnwrap(inFlight(makeAnimation().step(at: 9)))

        XCTAssertEqual(early.alpha, PermissionOverlayLaunchAnimation.initialAlpha, accuracy: 1e-9)
    }

    func test_finishesExactlyAtTheTargetOnceTheDurationHasElapsed() {
        let animation = makeAnimation()

        XCTAssertEqual(animation.step(at: 10 + PermissionOverlayLaunchAnimation.duration), .finished(frame: target))
        XCTAssertEqual(animation.step(at: 60), .finished(frame: target))
    }

    func test_alphaAndSizeGrowMonotonicallyTowardTheTarget() throws {
        let animation = makeAnimation()
        var previousAlpha = PermissionOverlayLaunchAnimation.initialAlpha
        var previousWidth = source.width

        for tick in 1..<12 {
            let step = try XCTUnwrap(inFlight(animation.step(at: 10 + (Double(tick) * 0.06))))
            XCTAssertGreaterThanOrEqual(step.alpha, previousAlpha)
            XCTAssertLessThanOrEqual(step.alpha, 1)
            XCTAssertGreaterThanOrEqual(step.frame.width, previousWidth)
            XCTAssertLessThanOrEqual(step.frame.width, target.width)
            previousAlpha = step.alpha
            previousWidth = step.frame.width
        }
    }

    func test_thePathArcsAboveBothEndpoints() throws {
        let midway = try XCTUnwrap(inFlight(makeAnimation().step(at: 10.12)))

        XCTAssertGreaterThan(midway.frame.midY, max(source.midY, target.midY))
    }

    func test_retargetingMidFlightLandsOnTheNewFrame() {
        var animation = makeAnimation()
        let moved = target.offsetBy(dx: 80, dy: -30)

        animation.toFrame = moved

        XCTAssertEqual(animation.step(at: 11), .finished(frame: moved))
    }
}
