import ApplicationServices
import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the event-tap boundary around acceptance.
///
/// The important invariant is ownership: the listen-only observer may classify ordinary typing, but
/// it must not perform acceptance because it cannot consume the original key event. The active
/// default tap owns acceptance so "insert suggestion" and "swallow this Tab" stay one decision.
final class InputMonitorTests: XCTestCase {
    func test_observerTapIgnoresAcceptanceKeySoConsumingTapOwnsIt() throws {
        try runOnMainActor {
            let monitor = makeMonitor()
            let event = try makeKeyboardEvent(keyCode: 48)
            var observedKinds: [CapturedInputEvent.Kind] = []
            monitor.onEvent = { event in
                observedKinds.append(event.kind)
                return true
            }

            let callbackResult = monitor.handleObserverTap(type: .keyDown, event: event)

            XCTAssertNotNil(callbackResult)
            XCTAssertTrue(observedKinds.isEmpty)
        }
    }

    func test_acceptTapConsumesOriginalKeyWhenCoordinatorAccepts() throws {
        try runOnMainActor {
            let monitor = makeMonitor()
            let event = try makeKeyboardEvent(keyCode: 48)
            var observedKinds: [CapturedInputEvent.Kind] = []
            monitor.shouldConsumeAcceptKeyProvider = { true }
            monitor.onEvent = { event in
                observedKinds.append(event.kind)
                return true
            }

            let callbackResult = monitor.handleAcceptTap(type: .keyDown, event: event)

            XCTAssertNil(callbackResult)
            XCTAssertEqual(observedKinds, [.acceptance])
        }
    }

    func test_acceptTapPassesOriginalKeyThroughWhenCoordinatorDeclines() throws {
        try runOnMainActor {
            let monitor = makeMonitor()
            let event = try makeKeyboardEvent(keyCode: 48)
            var observedKinds: [CapturedInputEvent.Kind] = []
            monitor.shouldConsumeAcceptKeyProvider = { true }
            monitor.onEvent = { event in
                observedKinds.append(event.kind)
                return false
            }

            let callbackResult = monitor.handleAcceptTap(type: .keyDown, event: event)

            XCTAssertNotNil(callbackResult)
            XCTAssertEqual(observedKinds, [.acceptance])
        }
    }

    func test_acceptTapPassesOriginalKeyThroughWhenPreflightFails() throws {
        try runOnMainActor {
            let monitor = makeMonitor()
            let event = try makeKeyboardEvent(keyCode: 48)
            monitor.shouldConsumeAcceptKeyProvider = { false }
            monitor.onEvent = { _ in
                XCTFail("Stale accept taps should not invoke coordinator acceptance.")
                return true
            }

            let callbackResult = monitor.handleAcceptTap(type: .keyDown, event: event)

            XCTAssertNotNil(callbackResult)
        }
    }

    @MainActor
    private func makeMonitor() -> InputMonitor {
        InputMonitor(
            permissionProvider: { true },
            suppressionController: InputSuppressionController()
        )
    }

    @MainActor
    private func makeKeyboardEvent(keyCode: CGKeyCode) throws -> CGEvent {
        try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
    }
}

private func runOnMainActor<Result>(
    _ body: @MainActor () throws -> Result
) rethrows -> Result {
    if Thread.isMainThread {
        return try MainActor.assumeIsolated(body)
    }

    return try DispatchQueue.main.sync {
        try MainActor.assumeIsolated(body)
    }
}
