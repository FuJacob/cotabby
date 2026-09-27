import XCTest
@testable import Cotabby

/// Tests for the gate that swallows single-poll `Supported -> Blocked -> Supported` flicker on the
/// same focused element while still letting real focus loss and element changes through promptly.
final class FocusCapabilityFlickerGateTests: XCTestCase {
    func testFirstSnapshotIsAlwaysApplied() {
        var gate = FocusCapabilityFlickerGate()
        XCTAssertEqual(gate.evaluate(supportedSnapshot(elementID: "field-A")), .apply)
    }

    func testSingleBlockedFlickerOnSameElementIsSuppressed() {
        var gate = FocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedSnapshot(elementID: "field-A"))

        let decision = gate.evaluate(blockedSnapshot(elementID: "field-A"))

        XCTAssertEqual(decision, .suppress(pendingBlockedReadCount: 1))
    }

    func testSupportedReturnAfterFlickerResetsTheGate() {
        var gate = FocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedSnapshot(elementID: "field-A"))
        _ = gate.evaluate(blockedSnapshot(elementID: "field-A"))

        XCTAssertEqual(gate.evaluate(supportedSnapshot(elementID: "field-A")), .apply)

        // After the reset, a fresh flicker is suppressed again rather than counted on top of the
        // previous run.
        XCTAssertEqual(
            gate.evaluate(blockedSnapshot(elementID: "field-A")),
            .suppress(pendingBlockedReadCount: 1)
        )
    }

    func testTwoConsecutiveBlockedReadsReleaseTheDowngrade() {
        var gate = FocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedSnapshot(elementID: "field-A"))

        XCTAssertEqual(
            gate.evaluate(blockedSnapshot(elementID: "field-A")),
            .suppress(pendingBlockedReadCount: 1)
        )
        XCTAssertEqual(gate.evaluate(blockedSnapshot(elementID: "field-A")), .apply)
    }

    func testBlockedAfterReleaseKeepsApplyingUntilSupportedRearmsTheGate() {
        var gate = FocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedSnapshot(elementID: "field-A"))
        _ = gate.evaluate(blockedSnapshot(elementID: "field-A"))
        XCTAssertEqual(gate.evaluate(blockedSnapshot(elementID: "field-A")), .apply)

        // Once the downgrade is released the gate is disarmed: a lingering Blocked field keeps
        // propagating instead of starting a fresh suppression window.
        XCTAssertEqual(gate.evaluate(blockedSnapshot(elementID: "field-A")), .apply)
    }

    func testSupportedOnANewElementMovesTheReference() {
        var gate = FocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedSnapshot(elementID: "field-A"))
        _ = gate.evaluate(supportedSnapshot(elementID: "field-B"))

        // The reference is now field-B: a flicker there is debounced, one on the old field is not.
        XCTAssertEqual(gate.evaluate(blockedSnapshot(elementID: "field-B")), .suppress(pendingBlockedReadCount: 1))
        XCTAssertEqual(gate.evaluate(blockedSnapshot(elementID: "field-A")), .apply)
    }

    func testBlockedOnDifferentElementBypassesSuppression() {
        var gate = FocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedSnapshot(elementID: "field-A"))

        XCTAssertEqual(gate.evaluate(blockedSnapshot(elementID: "field-B")), .apply)
    }

    func testBlockedWithoutAnyPriorSupportedIsApplied() {
        var gate = FocusCapabilityFlickerGate()
        XCTAssertEqual(gate.evaluate(blockedSnapshot(elementID: "field-A")), .apply)
    }

    func testUnsupportedIsNeverSuppressed() {
        var gate = FocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedSnapshot(elementID: "field-A"))

        XCTAssertEqual(gate.evaluate(unsupportedSnapshot()), .apply)
    }

    func testUnsupportedClearsPendingFlickerState() {
        var gate = FocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedSnapshot(elementID: "field-A"))
        _ = gate.evaluate(blockedSnapshot(elementID: "field-A"))
        _ = gate.evaluate(unsupportedSnapshot())

        // Without the clear, the next Blocked would resume the previous counter and downgrade
        // immediately. The Unsupported observation must reset everything.
        XCTAssertEqual(gate.evaluate(blockedSnapshot(elementID: "field-A")), .apply)
    }

    func testSupportedWithoutContextDoesNotArmTheGate() {
        var gate = FocusCapabilityFlickerGate()

        // A Supported snapshot with no context (rare but possible — e.g. capability inferred from
        // app identity before AX details settle) cannot be used as a reference for "same element"
        // checks, so the next Blocked must propagate immediately rather than be silently
        // suppressed.
        let supportedWithoutContext = FocusSnapshot(
            applicationName: "Calendar",
            bundleIdentifier: "com.apple.iCal",
            capability: .supported,
            context: nil
        )
        XCTAssertEqual(gate.evaluate(supportedWithoutContext), .apply)
        XCTAssertEqual(gate.evaluate(blockedSnapshot(elementID: "field-A")), .apply)
    }

    func testBlockedWithMissingContextIsAppliedEvenAfterSupported() {
        var gate = FocusCapabilityFlickerGate()
        _ = gate.evaluate(supportedSnapshot(elementID: "field-A"))

        // Loss of context on the snapshot means we can no longer prove "same element", so the
        // gate has to defer to the downstream evaluator instead of holding the field as Supported.
        let blockedWithoutContext = FocusSnapshot(
            applicationName: "Calendar",
            bundleIdentifier: "com.apple.iCal",
            capability: .blocked("Text is currently selected."),
            context: nil
        )
        XCTAssertEqual(gate.evaluate(blockedWithoutContext), .apply)
    }

    // MARK: - Helpers

    private func supportedSnapshot(elementID: String) -> FocusSnapshot {
        FocusSnapshot(
            applicationName: "Calendar",
            bundleIdentifier: "com.apple.iCal",
            capability: .supported,
            context: CotabbyTestFixtures.focusedInputSnapshot(elementIdentifier: elementID)
        )
    }

    private func blockedSnapshot(elementID: String) -> FocusSnapshot {
        FocusSnapshot(
            applicationName: "Calendar",
            bundleIdentifier: "com.apple.iCal",
            capability: .blocked("Text is currently selected."),
            context: CotabbyTestFixtures.focusedInputSnapshot(elementIdentifier: elementID)
        )
    }

    private func unsupportedSnapshot() -> FocusSnapshot {
        FocusSnapshot(
            applicationName: "Finder",
            bundleIdentifier: "com.apple.finder",
            capability: .unsupported("No focused text input"),
            context: nil
        )
    }
}
