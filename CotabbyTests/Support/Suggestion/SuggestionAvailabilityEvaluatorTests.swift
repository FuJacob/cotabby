import Combine
import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the gate every coordinator path runs through before starting a
/// generation. The value of concentrating these checks in one function is
/// precisely that UI copy and the gate logic can't drift; these tests lock
/// that contract in.
final class SuggestionAvailabilityEvaluatorTests: XCTestCase {

    // Build a FocusSnapshot with only the capability varied. Leaving context nil keeps each test
    // focused on the single gate axis under test.
    private func makeSnapshot(
        applicationName: String = "TestApp",
        bundleIdentifier: String? = "app.test",
        capability: FocusCapability
    ) -> FocusSnapshot {
        FocusSnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            capability: capability,
            context: nil
        )
    }

    private func makeSupportedSnapshotWithContext(
        elementIdentifier: String = "field",
        focusChangeSequence: UInt64 = 1,
        precedingText: String = "hello",
        focusedURLString: String? = nil
    ) -> FocusSnapshot {
        let context = FocusedInputSnapshot(
            applicationName: "TestApp",
            bundleIdentifier: "app.test",
            processIdentifier: 123,
            elementIdentifier: elementIdentifier,
            role: "AXTextField",
            subrole: nil,
            caretRect: .zero,
            inputFrameRect: nil,
            caretSource: "test",
            caretQuality: .exact,
            observedCharWidth: nil,
            precedingText: precedingText,
            trailingText: "",
            selection: NSRange(location: precedingText.count, length: 0),
            isSecure: false,
            focusChangeSequence: focusChangeSequence,
            focusedURLString: focusedURLString
        )

        return FocusSnapshot(
            applicationName: "TestApp",
            bundleIdentifier: "app.test",
            capability: .supported,
            context: context
        )
    }

    /// A supported focus snapshot whose field is an xterm.js integrated terminal. Bundle id is a
    /// non-terminal app (VS Code shares its bundle with the editor/chat), so only the surface-level
    /// `isIntegratedTerminal` flag distinguishes it.
    private func makeIntegratedTerminalSnapshot() -> FocusSnapshot {
        let context = CotabbyTestFixtures.focusedInputSnapshot(
            applicationName: "Code",
            bundleIdentifier: "com.microsoft.VSCode",
            role: "AXTextField",
            isIntegratedTerminal: true
        )
        return FocusSnapshot(
            applicationName: "Code",
            bundleIdentifier: "com.microsoft.VSCode",
            capability: .supported,
            context: context
        )
    }

    // MARK: - Integrated terminal gating

    func test_disabledReason_integratedTerminal_suppressedByDefault() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            inputMonitoringGranted: true,
            focusSnapshot: makeIntegratedTerminalSnapshot()
        )

        XCTAssertEqual(reason, "Cotabby is not available in the integrated terminal.")
    }

    func test_disabledReason_integratedTerminal_allowedWhenOptedIn() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            suggestInIntegratedTerminals: true,
            inputMonitoringGranted: true,
            focusSnapshot: makeIntegratedTerminalSnapshot()
        )

        XCTAssertNil(reason, "Opting in should let the integrated terminal suggest like any field")
    }

    func test_shouldSchedulePrediction_integratedTerminal_falseByDefault_trueWhenOptedIn() {
        let snapshot = makeIntegratedTerminalSnapshot()

        XCTAssertFalse(
            SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
                globallyEnabled: true,
                inputMonitoringGranted: true,
                focusSnapshot: snapshot
            )
        )
        XCTAssertTrue(
            SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
                globallyEnabled: true,
                suggestInIntegratedTerminals: true,
                inputMonitoringGranted: true,
                focusSnapshot: snapshot
            )
        )
    }

    // MARK: - disabledReason: exact-string contracts

    /// If this string ever changes, the menu-bar status copy will silently
    /// change alongside it. Pin it so any copy edit is deliberate.
    func test_disabledReason_whenGloballyDisabled_returnsFixedCopy() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: false,
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertEqual(reason, "Cotabby is turned off.")
    }

    func test_disabledReason_whenTemporarilyPaused_returnsPauseCopy() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            temporarilyPaused: true,
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertEqual(reason, "Cotabby is temporarily paused.")
    }

    func test_disabledReason_whenFocusedDomainIsDisabled_returnsSiteReason() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            disabledDomains: ["bank.com"],
            inputMonitoringGranted: true,
            focusSnapshot: makeSupportedSnapshotWithContext(focusedURLString: "https://www.bank.com/account")
        )

        XCTAssertEqual(reason, "Cotabby is disabled on bank.com.")
    }

    func test_disabledReason_domainCheckIsInertByDefault() {
        // A focused URL but no disabled-domains list: the per-site gate must never fire, so an
        // otherwise healthy environment stays enabled exactly as before this gate existed.
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            inputMonitoringGranted: true,
            focusSnapshot: makeSupportedSnapshotWithContext(focusedURLString: "https://bank.com/account")
        )

        XCTAssertNil(reason, "a focused URL with no disabled-domains list must not suppress autocomplete")
    }

    func test_disabledReason_whenInputMonitoringDenied_mentionsPermission() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            inputMonitoringGranted: false,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("Input Monitoring") ?? false,
                      "reason should point the user at the permission they need to grant")
    }

    // MARK: - disabledReason: guard ordering

    /// Global-off takes precedence over permission-denied. Important because
    /// the copy the user sees should be the thing they most need to know; if
    /// Cotabby is off, the Input Monitoring message is a distraction.
    func test_disabledReason_globalDisabled_winsOverInputMonitoringDenied() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: false,
            inputMonitoringGranted: false,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertEqual(reason, "Cotabby is turned off.")
    }

    func test_disabledReason_globalDisabled_winsOverAppDisabled() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: false,
            disabledAppBundleIdentifiers: ["app.test"],
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertEqual(reason, "Cotabby is turned off.")
    }

    func test_disabledReason_whenAppDisabled_returnsAppSpecificCopy() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            disabledAppBundleIdentifiers: ["com.apple.Safari"],
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(
                applicationName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                capability: .supported
            )
        )

        XCTAssertEqual(reason, "Cotabby is disabled in Safari.")
    }

    // MARK: - disabledReason: capability passthrough

    /// The .blocked and .unsupported cases both surface their own reason
    /// string so the menu can explain which field Cotabby is refusing to
    /// handle. Test that the evaluator passes these through verbatim.
    func test_disabledReason_blockedCapability_returnsCapabilityReason() {
        let blockReason = "Secure field — Cotabby intentionally won't run here."
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .blocked(blockReason))
        )

        XCTAssertEqual(reason, blockReason)
    }

    func test_disabledReason_unsupportedCapability_returnsCapabilityReason() {
        let unsupportedReason = "No focused text input"
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .unsupported(unsupportedReason))
        )

        XCTAssertEqual(reason, unsupportedReason)
    }

    // MARK: - disabledReason: happy path

    func test_disabledReason_whenEverythingAllowed_returnsNil() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertNil(reason)
    }

    // MARK: - shouldSchedulePrediction (boolean wrapper)

    /// shouldSchedulePrediction is the bool collapse of disabledReason == nil.
    /// Tests both sides of the nil boundary so a future refactor of one
    /// function without the other would trip.
    func test_shouldSchedulePrediction_trueWhenNoDisabledReason() {
        let ok = SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
            globallyEnabled: true,
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertTrue(ok)
    }

    func test_shouldSchedulePrediction_falseWhenGloballyDisabled() {
        let ok = SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
            globallyEnabled: false,
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertFalse(ok)
    }

    func test_shouldSchedulePrediction_falseWhenAppDisabled() {
        let ok = SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
            globallyEnabled: true,
            disabledAppBundleIdentifiers: ["app.test"],
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertFalse(ok)
    }

    func test_shouldSchedulePrediction_trueWhenDifferentAppDisabled() {
        let ok = SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
            globallyEnabled: true,
            disabledAppBundleIdentifiers: ["app.other"],
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .supported)
        )

        XCTAssertTrue(ok)
    }

    func test_shouldSchedulePrediction_falseWhenCapabilityUnsupported() {
        let ok = SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
            globallyEnabled: true,
            inputMonitoringGranted: true,
            focusSnapshot: makeSnapshot(capability: .unsupported("No focused text input"))
        )

        XCTAssertFalse(ok)
    }

    func test_visualContextReadyScheduling_trueWhenElementAndFocusSequenceMatch() {
        let snapshot = makeSupportedSnapshotWithContext(
            elementIdentifier: "field",
            focusChangeSequence: 42
        )

        let ok = SuggestionAvailabilityEvaluator.shouldSchedulePredictionWhenVisualContextBecomesReady(
            focusSnapshot: snapshot,
            matching: FocusedInputIdentity(elementIdentifier: "field", focusChangeSequence: 42)
        )

        XCTAssertTrue(ok)
    }

    func test_visualContextReadyScheduling_falseWhenFocusSequenceDiffers() {
        let snapshot = makeSupportedSnapshotWithContext(
            elementIdentifier: "field",
            focusChangeSequence: 42
        )

        let ok = SuggestionAvailabilityEvaluator.shouldSchedulePredictionWhenVisualContextBecomesReady(
            focusSnapshot: snapshot,
            matching: FocusedInputIdentity(elementIdentifier: "field", focusChangeSequence: 41)
        )

        XCTAssertFalse(ok)
    }

    // MARK: - shouldCaptureVisualContext + fast mode

    /// Mirror of the fast-mode invariant for the now-optional Screen Recording permission: a missing
    /// permission suppresses visual-context capture but leaves predictions running (text-only).
    func test_noScreenRecording_suppressesVisualContextButNotPredictions() {
        let snapshot = makeSnapshot(capability: .supported)

        XCTAssertFalse(
            SuggestionAvailabilityEvaluator.shouldCaptureVisualContext(
                inputMonitoringGranted: true,
                screenRecordingGranted: false,
                focusSnapshot: snapshot,
                isFastModeEnabled: false
            )
        )
        XCTAssertTrue(
            SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
                inputMonitoringGranted: true,
                focusSnapshot: snapshot
            )
        )
    }

    func test_shouldCaptureVisualContext_trueWhenAllowedAndNotFastMode() {
        let ok = SuggestionAvailabilityEvaluator.shouldCaptureVisualContext(
            globallyEnabled: true,
            inputMonitoringGranted: true,
            screenRecordingGranted: true,
            focusSnapshot: makeSnapshot(capability: .supported),
            isFastModeEnabled: false
        )

        XCTAssertTrue(ok)
    }

    /// The core fast-mode invariant: it turns off the screenshot/OCR pipeline while leaving the
    /// prediction gate untouched, so the user still gets (faster, context-free) completions.
    func test_fastMode_suppressesVisualContextButNotPredictions() {
        let snapshot = makeSnapshot(capability: .supported)

        XCTAssertFalse(
            SuggestionAvailabilityEvaluator.shouldCaptureVisualContext(
                inputMonitoringGranted: true,
                screenRecordingGranted: true,
                focusSnapshot: snapshot,
                isFastModeEnabled: true
            )
        )
        XCTAssertTrue(
            SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
                inputMonitoringGranted: true,
                focusSnapshot: snapshot
            )
        )
    }
}
