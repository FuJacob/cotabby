import XCTest
@testable import Cotabby

/// Tests for the gate every coordinator path runs through before starting a generation.
///
/// Concentrating these checks in one function means the menu-bar copy and the gate logic cannot
/// drift apart, so most assertions pin the exact user-facing string. The first matching guard wins,
/// which makes guard *ordering* part of the contract too: the user should see the most actionable
/// reason, not an incidental one.
final class SuggestionAvailabilityEvaluatorTests: XCTestCase {
    private static let turnedOff = "Cotabby is turned off."
    private static let paused = "Cotabby is temporarily paused."
    private static let lowPower = "Cotabby is paused because Low Power Mode is on."
    private static let terminalApp = "Cotabby is not available in terminal apps."
    private static let integratedTerminal = "Cotabby is not available in the integrated terminal."
    private static let inputMonitoring =
        "Input Monitoring permission is required before Cotabby can react to typing."

    /// A focus snapshot for one gate axis. Context is nil unless a test needs field-level facts
    /// (URL, integrated-terminal flag, identity, preceding text).
    private func makeSnapshot(
        applicationName: String = "TestApp",
        bundleIdentifier: String? = "app.test",
        capability: FocusCapability = .supported,
        context: FocusedInputSnapshot? = nil
    ) -> FocusSnapshot {
        FocusSnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            capability: capability,
            context: context
        )
    }

    /// A supported snapshot whose field is currently displaying `focusedURLString` in a browser.
    private func makeBrowserSnapshot(url: String) -> FocusSnapshot {
        makeSnapshot(context: CotabbyTestFixtures.focusedInputSnapshot(focusedURLString: url))
    }

    /// A supported focus snapshot whose field is an xterm.js integrated terminal. The bundle id is a
    /// non-terminal app (VS Code shares its bundle with the editor and chat), so only the AX-derived
    /// `isIntegratedTerminal` flag distinguishes it.
    private func makeIntegratedTerminalSnapshot() -> FocusSnapshot {
        makeSnapshot(
            applicationName: "Code",
            bundleIdentifier: "com.microsoft.VSCode",
            context: CotabbyTestFixtures.focusedInputSnapshot(
                applicationName: "Code",
                bundleIdentifier: "com.microsoft.VSCode",
                isIntegratedTerminal: true
            )
        )
    }

    /// Asserts both the reason string and that `shouldSchedulePrediction` agrees with it.
    ///
    /// `shouldSchedulePrediction` re-forwards every parameter to `disabledReason`; checking both at
    /// every call site catches a forwarding slip (for example, a dropped `disabledDomains`) that a
    /// handful of dedicated wrapper tests would miss.
    private func assertGate(
        _ expectedReason: String?,
        globallyEnabled: Bool = true,
        temporarilyPaused: Bool = false,
        isLowPowerModeActive: Bool = false,
        isLowPowerModeAutoDisableEnabled: Bool = false,
        disabledAppBundleIdentifiers: Set<String> = [],
        disabledDomains: Set<String> = [],
        suggestInIntegratedTerminals: Bool = false,
        inputMonitoringGranted: Bool = true,
        focusSnapshot: FocusSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: globallyEnabled,
            temporarilyPaused: temporarilyPaused,
            isLowPowerModeActive: isLowPowerModeActive,
            isLowPowerModeAutoDisableEnabled: isLowPowerModeAutoDisableEnabled,
            disabledAppBundleIdentifiers: disabledAppBundleIdentifiers,
            disabledDomains: disabledDomains,
            suggestInIntegratedTerminals: suggestInIntegratedTerminals,
            inputMonitoringGranted: inputMonitoringGranted,
            focusSnapshot: focusSnapshot
        )
        let shouldSchedule = SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
            globallyEnabled: globallyEnabled,
            temporarilyPaused: temporarilyPaused,
            isLowPowerModeActive: isLowPowerModeActive,
            isLowPowerModeAutoDisableEnabled: isLowPowerModeAutoDisableEnabled,
            disabledAppBundleIdentifiers: disabledAppBundleIdentifiers,
            disabledDomains: disabledDomains,
            suggestInIntegratedTerminals: suggestInIntegratedTerminals,
            inputMonitoringGranted: inputMonitoringGranted,
            focusSnapshot: focusSnapshot
        )

        XCTAssertEqual(reason, expectedReason, file: file, line: line)
        XCTAssertEqual(shouldSchedule, expectedReason == nil, "wrapper disagrees with reason", file: file, line: line)
    }

    // MARK: - Individual gates

    func test_everythingAllowed_hasNoReason() {
        assertGate(nil, focusSnapshot: makeSnapshot())
    }

    func test_globallyDisabled() {
        assertGate(Self.turnedOff, globallyEnabled: false, focusSnapshot: makeSnapshot())
    }

    func test_temporarilyPaused() {
        assertGate(Self.paused, temporarilyPaused: true, focusSnapshot: makeSnapshot())
    }

    /// Low Power Mode only pauses Cotabby when both the system state and the user's opt-in agree.
    func test_lowPowerMode_requiresActiveStateAndAutoDisable() {
        assertGate(
            Self.lowPower,
            isLowPowerModeActive: true,
            isLowPowerModeAutoDisableEnabled: true,
            focusSnapshot: makeSnapshot()
        )
        assertGate(
            nil,
            isLowPowerModeActive: true,
            isLowPowerModeAutoDisableEnabled: false,
            focusSnapshot: makeSnapshot()
        )
        assertGate(
            nil,
            isLowPowerModeActive: false,
            isLowPowerModeAutoDisableEnabled: true,
            focusSnapshot: makeSnapshot()
        )
    }

    func test_disabledApp_namesTheApplication() {
        assertGate(
            "Cotabby is disabled in Safari.",
            disabledAppBundleIdentifiers: ["com.apple.Safari"],
            focusSnapshot: makeSnapshot(applicationName: "Safari", bundleIdentifier: "com.apple.Safari")
        )
    }

    func test_disabledApp_onlyMatchesTheFocusedBundle() {
        assertGate(nil, disabledAppBundleIdentifiers: ["app.other"], focusSnapshot: makeSnapshot())
        // A snapshot without a bundle identifier can never match an app rule.
        assertGate(nil, disabledAppBundleIdentifiers: ["app.test"], focusSnapshot: makeSnapshot(bundleIdentifier: nil))
    }

    /// The reason names the normalized host (lowercased, `www.` dropped), and subdomains of a listed
    /// domain are covered.
    func test_disabledDomain_matchesNormalizedHostAndSubdomains() {
        assertGate(
            "Cotabby is disabled on bank.com.",
            disabledDomains: ["bank.com"],
            focusSnapshot: makeBrowserSnapshot(url: "https://WWW.Bank.com/account")
        )
        assertGate(
            "Cotabby is disabled on mail.bank.com.",
            disabledDomains: ["bank.com"],
            focusSnapshot: makeBrowserSnapshot(url: "https://mail.bank.com/inbox")
        )
    }

    func test_disabledDomain_isInertWithoutAMatchingRuleOrURL() {
        // A focused URL with no list, or with an unrelated entry, must not suppress autocomplete.
        assertGate(nil, focusSnapshot: makeBrowserSnapshot(url: "https://bank.com/account"))
        assertGate(nil, disabledDomains: ["bank.com"], focusSnapshot: makeBrowserSnapshot(url: "https://notbank.com"))
        // Without a resolved URL the domain gate has nothing to compare against.
        assertGate(nil, disabledDomains: ["bank.com"], focusSnapshot: makeSnapshot())
    }

    /// Standalone terminal emulators stay blocked even when integrated terminals are opted in:
    /// that opt-in only covers editor-hosted xterm.js surfaces.
    func test_terminalApp_isBlockedRegardlessOfIntegratedTerminalOptIn() {
        let terminal = makeSnapshot(applicationName: "Terminal", bundleIdentifier: "com.apple.Terminal")

        assertGate(Self.terminalApp, focusSnapshot: terminal)
        assertGate(Self.terminalApp, suggestInIntegratedTerminals: true, focusSnapshot: terminal)
    }

    func test_integratedTerminal_isBlockedUntilOptedIn() {
        assertGate(Self.integratedTerminal, focusSnapshot: makeIntegratedTerminalSnapshot())
        assertGate(nil, suggestInIntegratedTerminals: true, focusSnapshot: makeIntegratedTerminalSnapshot())
    }

    func test_inputMonitoringDenied_pointsAtThePermission() {
        assertGate(Self.inputMonitoring, inputMonitoringGranted: false, focusSnapshot: makeSnapshot())
    }

    /// `.blocked` and `.unsupported` both surface their own reason verbatim so the menu can explain
    /// which field Cotabby is refusing to handle.
    func test_capabilityReasonsPassThroughVerbatim() {
        let blocked = "Secure field — Cotabby intentionally won't run here."
        assertGate(blocked, focusSnapshot: makeSnapshot(capability: .blocked(blocked)))
        assertGate("No focused text input", focusSnapshot: makeSnapshot(capability: .unsupported("No focused text input")))
    }

    func test_checkCapabilityFalse_ignoresFieldCapabilityButKeepsEnvironmentGates() {
        let blocked = makeSnapshot(capability: .blocked("Text is selected."))

        XCTAssertNil(
            SuggestionAvailabilityEvaluator.disabledReason(
                inputMonitoringGranted: true,
                focusSnapshot: blocked,
                checkCapability: false
            )
        )
        XCTAssertEqual(
            SuggestionAvailabilityEvaluator.disabledReason(
                inputMonitoringGranted: false,
                focusSnapshot: blocked,
                checkCapability: false
            ),
            Self.inputMonitoring
        )
    }

    // MARK: - Guard ordering

    /// Each pair enables two gates at once; the earlier guard's copy must win. The order is
    /// global off > paused > Low Power > app > domain > terminal > Input Monitoring > capability.
    func test_guardOrdering_earlierGateWins() {
        let unsupported = makeSnapshot(capability: .unsupported("No focused text input"))

        assertGate(Self.turnedOff, globallyEnabled: false, temporarilyPaused: true, focusSnapshot: makeSnapshot())
        assertGate(Self.turnedOff, globallyEnabled: false, inputMonitoringGranted: false, focusSnapshot: makeSnapshot())
        assertGate(
            Self.paused,
            temporarilyPaused: true,
            isLowPowerModeActive: true,
            isLowPowerModeAutoDisableEnabled: true,
            focusSnapshot: makeSnapshot()
        )
        assertGate(
            Self.lowPower,
            isLowPowerModeActive: true,
            isLowPowerModeAutoDisableEnabled: true,
            disabledAppBundleIdentifiers: ["app.test"],
            focusSnapshot: makeSnapshot()
        )
        assertGate(
            "Cotabby is disabled in TestApp.",
            disabledAppBundleIdentifiers: ["app.test"],
            disabledDomains: ["bank.com"],
            focusSnapshot: makeBrowserSnapshot(url: "https://bank.com")
        )
        assertGate(
            "Cotabby is disabled in Terminal.",
            disabledAppBundleIdentifiers: ["com.apple.Terminal"],
            focusSnapshot: makeSnapshot(applicationName: "Terminal", bundleIdentifier: "com.apple.Terminal")
        )
        // Location rules beat the permission prompt: granting Input Monitoring would not help here.
        assertGate(
            "Cotabby is disabled in TestApp.",
            disabledAppBundleIdentifiers: ["app.test"],
            inputMonitoringGranted: false,
            focusSnapshot: makeSnapshot()
        )
        assertGate(Self.inputMonitoring, inputMonitoringGranted: false, focusSnapshot: unsupported)
    }

    // MARK: - shouldCaptureVisualContext

    func test_shouldCaptureVisualContext_trueWhenAllowed() {
        XCTAssertTrue(
            SuggestionAvailabilityEvaluator.shouldCaptureVisualContext(
                inputMonitoringGranted: true,
                screenRecordingGranted: true,
                focusSnapshot: makeSnapshot()
            )
        )
    }

    /// Capture skips the capability check on purpose: OCR should warm up while the field is in a
    /// transient state (text selected) so context is ready once the user starts typing.
    func test_shouldCaptureVisualContext_ignoresTransientFieldCapability() {
        XCTAssertTrue(
            SuggestionAvailabilityEvaluator.shouldCaptureVisualContext(
                inputMonitoringGranted: true,
                screenRecordingGranted: true,
                focusSnapshot: makeSnapshot(capability: .blocked("Text is selected."))
            )
        )
    }

    /// Fast mode and a missing Screen Recording permission suppress only the screenshot/OCR
    /// pipeline; predictions keep running text-only.
    func test_fastModeAndMissingScreenRecording_suppressCaptureButNotPredictions() {
        let snapshot = makeSnapshot()

        XCTAssertFalse(
            SuggestionAvailabilityEvaluator.shouldCaptureVisualContext(
                inputMonitoringGranted: true,
                screenRecordingGranted: true,
                focusSnapshot: snapshot,
                isFastModeEnabled: true
            )
        )
        XCTAssertFalse(
            SuggestionAvailabilityEvaluator.shouldCaptureVisualContext(
                inputMonitoringGranted: true,
                screenRecordingGranted: false,
                focusSnapshot: snapshot
            )
        )
        assertGate(nil, focusSnapshot: snapshot)
    }

    /// Environment gates still apply to capture: no screenshots in a paused, disabled, or
    /// permission-less state.
    func test_shouldCaptureVisualContext_respectsEnvironmentGates() {
        let snapshot = makeSnapshot()

        XCTAssertFalse(
            SuggestionAvailabilityEvaluator.shouldCaptureVisualContext(
                isLowPowerModeActive: true,
                isLowPowerModeAutoDisableEnabled: true,
                inputMonitoringGranted: true,
                screenRecordingGranted: true,
                focusSnapshot: snapshot
            )
        )
        XCTAssertFalse(
            SuggestionAvailabilityEvaluator.shouldCaptureVisualContext(
                disabledAppBundleIdentifiers: ["app.test"],
                inputMonitoringGranted: true,
                screenRecordingGranted: true,
                focusSnapshot: snapshot
            )
        )
        XCTAssertFalse(
            SuggestionAvailabilityEvaluator.shouldCaptureVisualContext(
                disabledDomains: ["bank.com"],
                inputMonitoringGranted: true,
                screenRecordingGranted: true,
                focusSnapshot: makeBrowserSnapshot(url: "https://bank.com")
            )
        )
        XCTAssertFalse(
            SuggestionAvailabilityEvaluator.shouldCaptureVisualContext(
                inputMonitoringGranted: false,
                screenRecordingGranted: true,
                focusSnapshot: snapshot
            )
        )
    }

    // MARK: - shouldSchedulePredictionWhenVisualContextBecomesReady

    func test_visualContextReady_schedulesOnlyForTheSameSupportedFocusWithText() {
        let identity = FocusedInputIdentity(elementIdentifier: "field", focusChangeSequence: 42)
        func context(
            elementIdentifier: String = "field",
            focusChangeSequence: UInt64 = 42,
            precedingText: String = "hello"
        ) -> FocusedInputSnapshot {
            CotabbyTestFixtures.focusedInputSnapshot(
                elementIdentifier: elementIdentifier,
                precedingText: precedingText,
                focusChangeSequence: focusChangeSequence
            )
        }

        let cases: [(name: String, snapshot: FocusSnapshot, expected: Bool)] = [
            ("matching focus", makeSnapshot(context: context()), true),
            ("focus sequence changed", makeSnapshot(context: context(focusChangeSequence: 41)), false),
            // CFHash-derived element identifiers can differ for the same sequence after AX churn.
            ("element changed", makeSnapshot(context: context(elementIdentifier: "other")), false),
            ("no context", makeSnapshot(), false),
            ("blocked capability", makeSnapshot(capability: .blocked("Secure field"), context: context()), false),
            ("blank field", makeSnapshot(context: context(precedingText: " \n ")), false)
        ]

        for testCase in cases {
            XCTAssertEqual(
                SuggestionAvailabilityEvaluator.shouldSchedulePredictionWhenVisualContextBecomesReady(
                    focusSnapshot: testCase.snapshot,
                    matching: identity
                ),
                testCase.expected,
                testCase.name
            )
        }
    }
}
