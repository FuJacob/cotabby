import ApplicationServices
import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the event-tap boundary around suggestion acceptance.
///
/// The key invariant is ownership: the listen-only observer may classify ordinary typing, but it
/// must not perform acceptance because it cannot consume the original key event. The active default
/// tap owns acceptance so "insert suggestion" and "swallow this key" stay one decision.
final class InputMonitorTests: XCTestCase {
    func test_observerTapIgnoresPrimaryAcceptKeyWhenConsumingTapOwnsIt() throws {
        try runOnMainActor {
            let monitor = makeMonitor()
            monitor.isAcceptTapOwningAcceptKeys = true
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

    func test_observerTapIgnoresFullAcceptKeyWhenConsumingTapOwnsIt() throws {
        try runOnMainActor {
            let monitor = makeMonitor()
            monitor.isAcceptTapOwningAcceptKeys = true
            monitor.fullAcceptanceKeyCodeProvider = { 50 }
            let event = try makeKeyboardEvent(keyCode: 50)
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

    func test_observerTapTreatsBarePrintableAcceptKeyAsTypingWhenConsumingTapIsInactive() throws {
        try runOnMainActor {
            let monitor = makeMonitor()
            monitor.acceptanceKeyCodeProvider = { 0 }
            let event = try makeKeyboardEvent(keyCode: 0, characters: "a")
            var observedKinds: [CapturedInputEvent.Kind] = []
            monitor.onEvent = { event in
                observedKinds.append(event.kind)
                return false
            }

            let callbackResult = monitor.handleObserverTap(type: .keyDown, event: event)

            XCTAssertNotNil(callbackResult)
            XCTAssertEqual(observedKinds, [.textMutation])
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

    func test_acceptTapConsumesBarePrintableBoundKeyWhenCoordinatorAccepts() throws {
        try runOnMainActor {
            let monitor = makeMonitor()
            monitor.acceptanceKeyCodeProvider = { 0 }
            let event = try makeKeyboardEvent(keyCode: 0)
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

    func test_acceptTapPassesBarePrintableBoundKeyThroughWhenNoVisibleSessionExists() throws {
        try runOnMainActor {
            let monitor = makeMonitor()
            monitor.acceptanceKeyCodeProvider = { 0 }
            let event = try makeKeyboardEvent(keyCode: 0)
            monitor.shouldConsumeAcceptKeyProvider = { false }
            monitor.onEvent = { _ in
                XCTFail("Bare printable shortcuts should only route into acceptance for visible sessions.")
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
    private func makeKeyboardEvent(keyCode: CGKeyCode, characters: String? = nil) throws -> CGEvent {
        let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true))
        if let characters {
            let utf16 = Array(characters.utf16)
            utf16.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
            }
        }
        return event
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
