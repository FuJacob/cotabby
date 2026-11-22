import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the event-tap boundary around suggestion acceptance and keystroke classification.
///
/// The key invariant is ownership: the listen-only observer may classify ordinary typing, but it
/// must not perform acceptance because it cannot consume the original key event. The active default
/// tap owns acceptance so "insert suggestion" and "swallow this key" stay one decision. Every test
/// enters through the semantic `InputMonitorKeyEvent` seams, so no real CGEvent tap is installed.
@MainActor
final class InputMonitorTests: XCTestCase {
    /// XCTest's app-host memory checker can deallocate `@MainActor` service objects outside the
    /// executor context Swift expects, which crashes in the runtime's actor deinit path.
    /// Retaining the handful of monitors for the process lifetime keeps these tests about routing.
    private static var retainedMonitors: [InputMonitor] = []

    private static let tab: CGKeyCode = 48
    private static let backtick: CGKeyCode = 50

    private func makeMonitor() -> InputMonitor {
        let monitor = InputMonitor(
            permissionProvider: { true },
            suppressionController: InputSuppressionController()
        )
        Self.retainedMonitors.append(monitor)
        return monitor
    }

    /// Installs an `onEvent` that records every delivered kind and answers with `accepts`.
    private func recordKinds(
        on monitor: InputMonitor,
        accepts: Bool
    ) -> () -> [CapturedInputEvent.Kind] {
        var kinds: [CapturedInputEvent.Kind] = []
        monitor.onEvent = { event in
            kinds.append(event.kind)
            return accepts
        }
        return { kinds }
    }

    // MARK: - Observer classification

    func test_observerClassifiesKeysByBehavior() {
        let cases: [(InputMonitorKeyEvent, CapturedInputEvent.Kind, String)] = [
            (InputMonitorKeyEvent(keyCode: 123), .navigation, "left arrow"),
            (InputMonitorKeyEvent(keyCode: 124), .navigation, "right arrow"),
            (InputMonitorKeyEvent(keyCode: 125), .navigation, "down arrow"),
            (InputMonitorKeyEvent(keyCode: 126), .navigation, "up arrow"),
            (InputMonitorKeyEvent(keyCode: 51), .textMutation, "backspace"),
            (InputMonitorKeyEvent(keyCode: 117), .textMutation, "forward delete"),
            (InputMonitorKeyEvent(keyCode: 53), .dismissal, "escape"),
            (InputMonitorKeyEvent(keyCode: 36, characters: "\r"), .dismissal, "return is not typing"),
            (InputMonitorKeyEvent(keyCode: 76), .dismissal, "keypad enter"),
            (InputMonitorKeyEvent(keyCode: 0, flags: .maskCommand), .shortcutMutation, "cmd-A"),
            (InputMonitorKeyEvent(keyCode: 6, flags: .maskCommand), .shortcutMutation, "cmd-Z"),
            (InputMonitorKeyEvent(keyCode: 7, flags: .maskCommand), .shortcutMutation, "cmd-X"),
            (InputMonitorKeyEvent(keyCode: 9, flags: .maskCommand), .shortcutMutation, "cmd-V"),
            (InputMonitorKeyEvent(keyCode: 8, characters: "c", flags: .maskCommand), .dismissal, "cmd-C"),
            (InputMonitorKeyEvent(keyCode: 0, characters: "a"), .textMutation, "printable letter"),
            (InputMonitorKeyEvent(keyCode: 49, characters: " "), .textMutation, "space"),
            (InputMonitorKeyEvent(keyCode: 122, characters: "\u{10}"), .other, "control character only"),
            (InputMonitorKeyEvent(keyCode: 56), .other, "bare modifier with no characters")
        ]

        for (event, expectedKind, label) in cases {
            let monitor = makeMonitor()
            let delivered = recordKinds(on: monitor, accepts: false)

            let captured = monitor.handleObserverKeyDown(event)

            XCTAssertEqual(captured?.kind, expectedKind, label)
            XCTAssertEqual(delivered(), [expectedKind], label)
        }
    }

    func test_observerPreservesTypedCharactersOnlyForTextMutations() {
        let monitor = makeMonitor()
        _ = recordKinds(on: monitor, accepts: false)

        XCTAssertEqual(monitor.handleObserverKeyDown(InputMonitorKeyEvent(keyCode: 0, characters: "a"))?.characters, "a")
        // Structural keys drop their characters so the coordinator never mistakes "\r" for text.
        XCTAssertEqual(monitor.handleObserverKeyDown(InputMonitorKeyEvent(keyCode: 36, characters: "\r"))?.characters, "")
    }

    func test_observerSkipsClassificationWhenEventsShouldNotBeProcessed() {
        let monitor = makeMonitor()
        monitor.shouldProcessEventsProvider = { false }
        let delivered = recordKinds(on: monitor, accepts: true)

        XCTAssertNil(monitor.handleObserverKeyDown(InputMonitorKeyEvent(keyCode: 0, characters: "a")))
        XCTAssertTrue(delivered().isEmpty)
    }

    func test_observerTapForwardsPointerLocationWithoutConsumingIt() {
        let monitor = makeMonitor()
        var observedPoint: CGPoint?
        monitor.onPointerDown = { observedPoint = $0 }

        monitor.handleObserverPointerDown(at: CGPoint(x: 321, y: 654))

        XCTAssertEqual(observedPoint, CGPoint(x: 321, y: 654))
    }

    // MARK: - Observer vs. accept-tap ownership

    func test_observerIgnoresAcceptKeysWhenConsumingTapOwnsThem() {
        let bindings: [(label: String, keyCode: CGKeyCode)] = [("word accept", Self.tab), ("full accept", Self.backtick)]
        for binding in bindings {
            let monitor = makeMonitor()
            monitor.isAcceptTapOwningAcceptKeys = true
            monitor.fullAcceptanceBindingProvider = { (Self.backtick, []) }
            let delivered = recordKinds(on: monitor, accepts: true)

            XCTAssertNil(monitor.handleObserverKeyDown(InputMonitorKeyEvent(keyCode: binding.keyCode)), binding.label)
            XCTAssertTrue(delivered().isEmpty, binding.label)
        }
    }

    /// Regression: while an emoji `:query` capture is open, the observer must keep routing the accept
    /// key (Tab) to `onEvent` even when a ghost suggestion is concurrently visible (which sets
    /// `isAcceptTapOwningAcceptKeys`). The emoji commit fires from this observer pass; suppressing the
    /// key here let a late async suggestion steal the first Tab, so the emoji never landed on the first
    /// try and only worked once the suggestion had cleared.
    func test_observerRoutesAcceptKeyToEmojiObserverWhileCapturingDespiteVisibleSuggestion() {
        let monitor = makeMonitor()
        // Staged directly: `setCaptureInterceptionActive` would install a real CGEvent tap.
        monitor.captureInterceptionActive = true
        monitor.isAcceptTapOwningAcceptKeys = true
        let delivered = recordKinds(on: monitor, accepts: false)

        let captured = monitor.handleObserverKeyDown(InputMonitorKeyEvent(keyCode: Self.tab))

        // Tab with no printable characters classifies as `.other`, never as acceptance.
        XCTAssertEqual(captured?.kind, .other)
        XCTAssertEqual(delivered(), [.other])
    }

    func test_observerTreatsBarePrintableAcceptKeyAsTypingWhenConsumingTapIsInactive() {
        let monitor = makeMonitor()
        monitor.acceptanceBindingProvider = { (0, []) }
        let delivered = recordKinds(on: monitor, accepts: false)

        let captured = monitor.handleObserverKeyDown(InputMonitorKeyEvent(keyCode: 0, characters: "a"))

        XCTAssertEqual(captured?.kind, .textMutation)
        XCTAssertEqual(delivered(), [.textMutation])
    }

    // MARK: - Accept tap

    func test_acceptTapConsumesOnlyWhenPreflightAndCoordinatorBothAgree() {
        let cases: [(preflight: Bool, coordinatorAccepts: Bool, expected: InputMonitorAcceptTapDecision, delivered: [CapturedInputEvent.Kind])] = [
            (true, true, .consume, [.acceptance]),
            (true, false, .passThrough, [.acceptance]),
            // A stale tap with no visible suggestion must not even ask the coordinator.
            (false, true, .passThrough, [])
        ]

        for testCase in cases {
            let monitor = makeMonitor()
            let preflight = testCase.preflight
            monitor.shouldConsumeAcceptKeyProvider = { preflight }
            let delivered = recordKinds(on: monitor, accepts: testCase.coordinatorAccepts)

            let decision = monitor.handleAcceptKeyDown(InputMonitorKeyEvent(keyCode: Self.tab))

            let label = "preflight=\(testCase.preflight) accepts=\(testCase.coordinatorAccepts)"
            XCTAssertEqual(decision, testCase.expected, label)
            XCTAssertEqual(delivered(), testCase.delivered, label)
        }
    }

    func test_acceptTapConsumesBarePrintableBoundKeyOnlyForVisibleSuggestions() {
        for preflight in [true, false] {
            let monitor = makeMonitor()
            monitor.acceptanceBindingProvider = { (0, []) }
            monitor.shouldConsumeAcceptKeyProvider = { preflight }
            let delivered = recordKinds(on: monitor, accepts: true)

            let decision = monitor.handleAcceptKeyDown(InputMonitorKeyEvent(keyCode: 0))

            XCTAssertEqual(decision, preflight ? .consume : .passThrough)
            XCTAssertEqual(delivered(), preflight ? [.acceptance] : [])
        }
    }

    func test_acceptTapLeavesNonAcceptKeysUnhandled() {
        let monitor = makeMonitor()
        monitor.shouldConsumeAcceptKeyProvider = { true }
        let delivered = recordKinds(on: monitor, accepts: true)

        XCTAssertEqual(monitor.handleAcceptKeyDown(InputMonitorKeyEvent(keyCode: 0, characters: "a")), .notHandled)
        XCTAssertTrue(delivered().isEmpty)
    }

    func test_acceptTapPassesThroughWithoutAnEventHandler() {
        let monitor = makeMonitor()
        monitor.shouldConsumeAcceptKeyProvider = { true }

        XCTAssertEqual(monitor.handleAcceptKeyDown(InputMonitorKeyEvent(keyCode: Self.tab)), .passThrough)
    }

    func test_acceptTapPassesThroughWhenEventsShouldNotBeProcessed() {
        let monitor = makeMonitor()
        monitor.shouldProcessEventsProvider = { false }
        monitor.shouldConsumeAcceptKeyProvider = { true }
        let delivered = recordKinds(on: monitor, accepts: true)

        XCTAssertEqual(monitor.handleAcceptKeyDown(InputMonitorKeyEvent(keyCode: Self.tab)), .passThrough)
        XCTAssertTrue(delivered().isEmpty)
    }

    func test_acceptTapRequiresExactModifierMatch() {
        let monitor = makeMonitor()
        monitor.shouldConsumeAcceptKeyProvider = { true }
        let delivered = recordKinds(on: monitor, accepts: true)

        // Tab is bound with no modifiers, so Shift+Tab (reverse focus traversal) must stay untouched.
        XCTAssertEqual(monitor.handleAcceptKeyDown(InputMonitorKeyEvent(keyCode: Self.tab, flags: .maskShift)), .notHandled)
        // Non-modifier flags such as caps lock are normalized away and do not break the match.
        XCTAssertEqual(monitor.handleAcceptKeyDown(InputMonitorKeyEvent(keyCode: Self.tab, flags: .maskAlphaShift)), .consume)
        XCTAssertEqual(delivered(), [.acceptance])
    }

    func test_acceptTapTellsTheCoordinatorWhichPressesAreKeyRepeats() {
        let monitor = makeMonitor()
        monitor.shouldConsumeAcceptKeyProvider = { true }
        var repeatFlags: [Bool] = []
        monitor.onEvent = { event in
            repeatFlags.append(event.isAutorepeat)
            return true
        }

        XCTAssertEqual(monitor.handleAcceptKeyDown(InputMonitorKeyEvent(keyCode: Self.tab)), .consume)
        XCTAssertEqual(monitor.handleAcceptKeyDown(InputMonitorKeyEvent(keyCode: Self.tab, isAutorepeat: true)), .consume)

        // A held key still accepts, but double-tap recognition must see it as one long press.
        XCTAssertEqual(repeatFlags, [false, true])
    }

    func test_fullAcceptBindingWinsWhenBothBindingsShareAKey() {
        let monitor = makeMonitor()
        monitor.fullAcceptanceBindingProvider = { (Self.tab, []) }
        monitor.shouldConsumeAcceptKeyProvider = { true }
        let delivered = recordKinds(on: monitor, accepts: true)

        XCTAssertEqual(monitor.handleAcceptKeyDown(InputMonitorKeyEvent(keyCode: Self.tab)), .consume)
        XCTAssertEqual(delivered(), [.fullAcceptance])
        XCTAssertFalse(monitor.isWordAcceptKey(InputMonitorKeyEvent(keyCode: Self.tab)))
    }

    func test_isWordAcceptKey_matchesOnlyTheConfiguredWordAcceptBinding() {
        let monitor = makeMonitor()
        monitor.fullAcceptanceBindingProvider = { (Self.backtick, []) }

        XCTAssertTrue(monitor.isWordAcceptKey(InputMonitorKeyEvent(keyCode: Self.tab)))
        XCTAssertFalse(monitor.isWordAcceptKey(InputMonitorKeyEvent(keyCode: Self.backtick)), "full-accept key")
        XCTAssertFalse(monitor.isWordAcceptKey(InputMonitorKeyEvent(keyCode: 36)), "Return")
    }

    // MARK: - Emoji capture decider

    func test_emojiDeciderResolvesKeysBeforeAcceptLogic() {
        let cases: [(decider: InputMonitorAcceptTapDecision, expected: InputMonitorAcceptTapDecision, delivered: [CapturedInputEvent.Kind])] = [
            // A capture consumes navigation keys that are not accept keys at all.
            (.consume, .consume, []),
            // A capture can let the accept key through even though the accept path would consume it.
            (.passThrough, .passThrough, []),
            // No capture active: the normal accept-key path decides.
            (.notHandled, .consume, [.acceptance])
        ]

        for testCase in cases {
            let monitor = makeMonitor()
            let deciderResult = testCase.decider
            monitor.emojiCaptureKeyDecider = { _ in deciderResult }
            monitor.shouldConsumeAcceptKeyProvider = { true }
            let delivered = recordKinds(on: monitor, accepts: true)

            let decision = monitor.resolveAcceptKeyDown(InputMonitorKeyEvent(keyCode: Self.tab))

            XCTAssertEqual(decision, testCase.expected, "decider=\(testCase.decider)")
            XCTAssertEqual(delivered(), testCase.delivered, "decider=\(testCase.decider)")
        }
    }

    func test_withoutEmojiDeciderResolveMatchesAcceptLogic() {
        let monitor = makeMonitor()
        monitor.shouldConsumeAcceptKeyProvider = { true }
        _ = recordKinds(on: monitor, accepts: true)

        XCTAssertEqual(monitor.resolveAcceptKeyDown(InputMonitorKeyEvent(keyCode: Self.tab)), .consume)
        XCTAssertEqual(monitor.resolveAcceptKeyDown(InputMonitorKeyEvent(keyCode: 125)), .notHandled)
    }
}
