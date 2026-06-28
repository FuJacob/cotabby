import XCTest
@testable import Cotabby

/// Tests for the event-tap boundary around suggestion acceptance.
///
/// The key invariant is ownership: the listen-only observer may classify ordinary typing, but it
/// must not perform acceptance because it cannot consume the original key event. The active default
/// tap owns acceptance so "insert suggestion" and "swallow this key" stay one decision.
final class InputMonitorTests: XCTestCase {
    /// XCTest's app-host memory checker can deallocate `@MainActor` service objects outside the
    /// executor context Swift expects, which currently crashes in the runtime's actor deinit path.
    /// These tests create only a small fixed number of monitors, so retaining them for the test
    /// process lifetime keeps the tests focused on routing behavior instead of deinit mechanics.
    @MainActor private static var retainedMonitors: [InputMonitor] = []

    func test_observerTapIgnoresPrimaryAcceptKeyWhenConsumingTapOwnsIt() {
        runOnMainActor {
            let monitor = makeMonitor()
            monitor.isAcceptTapOwningAcceptKeys = true
            var observedKinds: [CapturedInputEvent.Kind] = []
            monitor.onEvent = { event in
                observedKinds.append(event.kind)
                return true
            }

            let capturedEvent = monitor.handleObserverKeyDown(InputMonitorKeyEvent(keyCode: 48))

            XCTAssertNil(capturedEvent)
            XCTAssertTrue(observedKinds.isEmpty)
        }
    }

    /// Regression: while an emoji `:query` capture is open, the observer must keep routing the accept
    /// key (Tab) to `onEvent` even when a ghost suggestion is concurrently visible (which sets
    /// `isAcceptTapOwningAcceptKeys`). The emoji commit fires from this observer pass; suppressing the
    /// key here let a late async suggestion steal the first Tab, so the emoji never landed on the first
    /// try and only worked once the suggestion had cleared.
    func test_observerTapRoutesAcceptKeyToEmojiObserverWhileCapturingDespiteVisibleSuggestion() {
        runOnMainActor {
            let monitor = makeMonitor()
            monitor.acceptanceBindingProvider = { (48, []) }   // Tab is the word-accept key
            // Stage both conditions: a visible suggestion owns the accept key, AND an emoji capture is
            // open. (Set after the capture flag because `setCaptureInterceptionActive` recomputes
            // ownership; we stage it directly to avoid installing real CGEvent taps in the test host.)
            monitor.captureInterceptionActive = true
            monitor.isAcceptTapOwningAcceptKeys = true
            var observedKinds: [CapturedInputEvent.Kind] = []
            monitor.onEvent = { event in
                observedKinds.append(event.kind)
                return false
            }

            let capturedEvent = monitor.handleObserverKeyDown(InputMonitorKeyEvent(keyCode: 48))

            // The key must reach the emoji observer and must NOT be classified as acceptance.
            XCTAssertNotNil(capturedEvent)
            XCTAssertNotEqual(capturedEvent?.kind, .acceptance)
            XCTAssertEqual(observedKinds.count, 1)
            XCTAssertNotEqual(observedKinds.first, .acceptance)
        }
    }

    func test_observerTapIgnoresFullAcceptKeyWhenConsumingTapOwnsIt() {
        runOnMainActor {
            let monitor = makeMonitor()
            monitor.isAcceptTapOwningAcceptKeys = true
            monitor.fullAcceptanceBindingProvider = { (50, []) }
            var observedKinds: [CapturedInputEvent.Kind] = []
            monitor.onEvent = { event in
                observedKinds.append(event.kind)
                return true
            }

            let capturedEvent = monitor.handleObserverKeyDown(InputMonitorKeyEvent(keyCode: 50))

            XCTAssertNil(capturedEvent)
            XCTAssertTrue(observedKinds.isEmpty)
        }
    }

    func test_observerTapTreatsBarePrintableAcceptKeyAsTypingWhenConsumingTapIsInactive() {
        runOnMainActor {
            let monitor = makeMonitor()
            monitor.acceptanceBindingProvider = { (0, []) }
            var observedKinds: [CapturedInputEvent.Kind] = []
            monitor.onEvent = { event in
                observedKinds.append(event.kind)
                return false
            }

            let capturedEvent = monitor.handleObserverKeyDown(
                InputMonitorKeyEvent(keyCode: 0, characters: "a")
            )

            XCTAssertEqual(capturedEvent?.kind, .textMutation)
            XCTAssertEqual(observedKinds, [.textMutation])
        }
    }

    func test_acceptTapConsumesOriginalKeyWhenCoordinatorAccepts() {
        runOnMainActor {
            let monitor = makeMonitor()
            var observedKinds: [CapturedInputEvent.Kind] = []
            monitor.shouldConsumeAcceptKeyProvider = { true }
            monitor.onEvent = { event in
                observedKinds.append(event.kind)
                return true
            }

            let decision = monitor.handleAcceptKeyDown(InputMonitorKeyEvent(keyCode: 48))

            XCTAssertEqual(decision, .consume)
            XCTAssertEqual(observedKinds, [.acceptance])
        }
    }

    func test_acceptTapPassesOriginalKeyThroughWhenCoordinatorDeclines() {
        runOnMainActor {
            let monitor = makeMonitor()
            var observedKinds: [CapturedInputEvent.Kind] = []
            monitor.shouldConsumeAcceptKeyProvider = { true }
            monitor.onEvent = { event in
                observedKinds.append(event.kind)
                return false
            }

            let decision = monitor.handleAcceptKeyDown(InputMonitorKeyEvent(keyCode: 48))

            XCTAssertEqual(decision, .passThrough)
            XCTAssertEqual(observedKinds, [.acceptance])
        }
    }

    func test_acceptTapPassesOriginalKeyThroughWhenPreflightFails() {
        runOnMainActor {
            let monitor = makeMonitor()
            monitor.shouldConsumeAcceptKeyProvider = { false }
            monitor.onEvent = { _ in
                XCTFail("Stale accept taps should not invoke coordinator acceptance.")
                return true
            }

            let decision = monitor.handleAcceptKeyDown(InputMonitorKeyEvent(keyCode: 48))

            XCTAssertEqual(decision, .passThrough)
        }
    }

    func test_acceptTapConsumesBarePrintableBoundKeyWhenCoordinatorAccepts() {
        runOnMainActor {
            let monitor = makeMonitor()
            monitor.acceptanceBindingProvider = { (0, []) }
            var observedKinds: [CapturedInputEvent.Kind] = []
            monitor.shouldConsumeAcceptKeyProvider = { true }
            monitor.onEvent = { event in
                observedKinds.append(event.kind)
                return true
            }

            let decision = monitor.handleAcceptKeyDown(InputMonitorKeyEvent(keyCode: 0))

            XCTAssertEqual(decision, .consume)
            XCTAssertEqual(observedKinds, [.acceptance])
        }
    }

    func test_acceptTapPassesBarePrintableBoundKeyThroughWhenNoVisibleSuggestionExists() {
        runOnMainActor {
            let monitor = makeMonitor()
            monitor.acceptanceBindingProvider = { (0, []) }
            monitor.shouldConsumeAcceptKeyProvider = { false }
            monitor.onEvent = { _ in
                XCTFail("Bare printable shortcuts should only route into acceptance for visible suggestions.")
                return true
            }

            let decision = monitor.handleAcceptKeyDown(InputMonitorKeyEvent(keyCode: 0))

            XCTAssertEqual(decision, .passThrough)
        }
    }

    // MARK: - Emoji capture decider

    func test_emojiDecider_consumeTakesPrecedenceOverAcceptLogic() {
        runOnMainActor {
            let monitor = makeMonitor()
            monitor.emojiCaptureKeyDecider = { _ in .consume }
            monitor.shouldConsumeAcceptKeyProvider = { false }
            monitor.onEvent = { _ in
                XCTFail("Emoji capture should resolve the key before the accept-key path runs.")
                return true
            }

            // Down arrow (125) is not an accept key, yet the emoji decider consumes it during capture.
            let decision = monitor.resolveAcceptKeyDown(InputMonitorKeyEvent(keyCode: 125))

            XCTAssertEqual(decision, .consume)
        }
    }

    func test_emojiDecider_passThroughTakesPrecedenceOverAcceptKey() {
        runOnMainActor {
            let monitor = makeMonitor()
            monitor.emojiCaptureKeyDecider = { _ in .passThrough }
            // The accept key (48) would normally consume, but the emoji decider lets it through.
            monitor.shouldConsumeAcceptKeyProvider = { true }
            monitor.onEvent = { _ in true }

            let decision = monitor.resolveAcceptKeyDown(InputMonitorKeyEvent(keyCode: 48))

            XCTAssertEqual(decision, .passThrough)
        }
    }

    func test_emojiDecider_notHandledFallsThroughToAcceptLogic() {
        runOnMainActor {
            let monitor = makeMonitor()
            monitor.emojiCaptureKeyDecider = { _ in .notHandled }
            var observedKinds: [CapturedInputEvent.Kind] = []
            monitor.shouldConsumeAcceptKeyProvider = { true }
            monitor.onEvent = { event in
                observedKinds.append(event.kind)
                return true
            }

            let decision = monitor.resolveAcceptKeyDown(InputMonitorKeyEvent(keyCode: 48))

            XCTAssertEqual(decision, .consume)
            XCTAssertEqual(observedKinds, [.acceptance], "Accept-key path still runs when no capture is active")
        }
    }

    func test_noEmojiDecider_usesAcceptLogicUnchanged() {
        runOnMainActor {
            let monitor = makeMonitor()
            monitor.shouldConsumeAcceptKeyProvider = { true }
            monitor.onEvent = { _ in true }

            let decision = monitor.resolveAcceptKeyDown(InputMonitorKeyEvent(keyCode: 48))

            XCTAssertEqual(decision, .consume)
        }
    }

    func test_isWordAcceptKey_matchesOnlyTheConfiguredWordAcceptBinding() {
        runOnMainActor {
            let monitor = makeMonitor()
            monitor.acceptanceBindingProvider = { (48, []) }          // Tab is the word-accept key
            monitor.fullAcceptanceBindingProvider = { (50, []) }      // backtick is full-accept

            XCTAssertTrue(monitor.isWordAcceptKey(InputMonitorKeyEvent(keyCode: 48)))
            XCTAssertFalse(
                monitor.isWordAcceptKey(InputMonitorKeyEvent(keyCode: 50)),
                "The full-accept key must not count as the word-accept key."
            )
            XCTAssertFalse(
                monitor.isWordAcceptKey(InputMonitorKeyEvent(keyCode: 36)),
                "Return must not count as the word-accept key."
            )
        }
    }

    @MainActor
    private func makeMonitor() -> InputMonitor {
        let monitor = InputMonitor(
            permissionProvider: { true },
            suppressionController: InputSuppressionController()
        )
        Self.retainedMonitors.append(monitor)
        return monitor
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
