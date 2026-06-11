import Combine
import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the gate every coordinator path runs through before starting a
/// generation. The value of concentrating these checks in one function is
/// precisely that UI copy and the gate logic can't drift; these tests lock
/// that contract in.
final class SuggestionAvailabilityEvaluatorTests: XCTestCase {

    // Build a FocusSnapshot with only the capability varied — none of the gate
    // logic we're testing here touches `context` or `inspection`, so leaving
    // them nil keeps each test focused on the single axis under test.
    private func makeSnapshot(
        applicationName: String = "TestApp",
        bundleIdentifier: String? = "app.test",
        capability: FocusCapability
    ) -> FocusSnapshot {
        FocusSnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            capability: capability,
            context: nil,
            inspection: nil
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
            context: context,
            inspection: nil
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
            context: context,
            inspection: nil
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

/// Tests for the app identity that menu-bar controls target.
///
/// This is deliberately a pure model test instead of a SwiftUI test. The behavior we care about is
/// not pixels; it is the invariant that Cotabby's own transient focus does not become the app rule
/// target after the user opens the menu bar.
final class FocusSnapshotExternalApplicationIdentityTests: XCTestCase {
    func test_externalApplicationIdentity_returnsNonCotabbyApplication() {
        let snapshot = FocusSnapshot(
            applicationName: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            capability: .supported,
            context: nil,
            inspection: nil
        )

        XCTAssertEqual(
            snapshot.externalApplicationIdentity(ignoredBundleIdentifier: "com.jacobfu.tabby"),
            FocusedApplicationIdentity(
                applicationName: "Google Chrome",
                bundleIdentifier: "com.google.Chrome"
            )
        )
    }

    func test_externalApplicationIdentity_ignoresCotabbyApplication() {
        let snapshot = FocusSnapshot(
            applicationName: "Cotabby",
            bundleIdentifier: "com.jacobfu.tabby",
            capability: .blocked("Cotabby is focused."),
            context: nil,
            inspection: nil
        )

        XCTAssertNil(
            snapshot.externalApplicationIdentity(ignoredBundleIdentifier: "com.jacobfu.tabby")
        )
    }

    func test_externalApplicationIdentity_returnsNilWhenBundleIdentifierIsMissing() {
        let snapshot = FocusSnapshot(
            applicationName: "Unknown",
            bundleIdentifier: nil,
            capability: .unsupported("No active application."),
            context: nil,
            inspection: nil
        )

        XCTAssertNil(
            snapshot.externalApplicationIdentity(ignoredBundleIdentifier: "com.jacobfu.tabby")
        )
    }
}

/// Tests for the durable disabled-app blocklist.
///
/// These live beside the evaluator tests because the two pieces form one contract: settings own
/// persistence, while the evaluator consumes the snapshot produced from those settings.
final class SuggestionSettingsModelDisabledAppsTests: XCTestCase {
    /// Hosted macOS tests are currently crashing while deallocating short-lived
    /// `SuggestionSettingsModel` instances. Retaining the models for the full process lifetime
    /// quarantines that runtime issue so these tests can keep asserting the persistence contract.
    private static var retainedModels: [SuggestionSettingsModel] = []

    /// Keep the suite object and its name together so teardown clears the exact domain each test
    /// created. This avoids reaching back through `UserDefaults.standard`, which is a broader
    /// global API surface than these tests actually need.
    private var userDefaultsSuites: [(suiteName: String, userDefaults: UserDefaults)] = []

    override func tearDown() {
        for suite in userDefaultsSuites {
            suite.userDefaults.removePersistentDomain(forName: suite.suiteName)
        }
        userDefaultsSuites.removeAll()
        super.tearDown()
    }

    func test_disabledAppRules_surviveModelRecreation() {
        runOnMainActor {
            let userDefaults = makeUserDefaults()
            let model = makeModel(userDefaults: userDefaults)

            model.disableApplication(
                bundleIdentifier: "com.apple.Safari",
                displayName: "Safari"
            )

            let reloadedModel = makeModel(userDefaults: userDefaults)

            XCTAssertEqual(
                reloadedModel.disabledAppRules,
                [
                    DisabledApplicationRule(
                        bundleIdentifier: "com.apple.Safari",
                        displayName: "Safari"
                    )
                ]
            )
        }
    }

    func test_disableApplication_reusesBundleIdentifierInsteadOfDuplicating() {
        runOnMainActor {
            let model = makeModel()

            model.disableApplication(
                bundleIdentifier: "com.apple.Safari",
                displayName: "Safari"
            )
            model.disableApplication(
                bundleIdentifier: "com.apple.Safari",
                displayName: "Safari Technology Preview"
            )

            XCTAssertEqual(model.disabledAppRules.count, 1)
            XCTAssertEqual(
                model.disabledAppRules.first?.displayName,
                "Safari Technology Preview"
            )
        }
    }

    func test_removeDisabledApplication_deletesOnlyMatchingBundleIdentifier() {
        runOnMainActor {
            let model = makeModel()

            model.disableApplication(
                bundleIdentifier: "com.apple.Safari",
                displayName: "Safari"
            )
            model.disableApplication(
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                displayName: "Slack"
            )
            model.removeDisabledApplication(bundleIdentifier: "com.apple.Safari")

            XCTAssertFalse(model.isApplicationDisabled(bundleIdentifier: "com.apple.Safari"))
            XCTAssertTrue(
                model.isApplicationDisabled(bundleIdentifier: "com.tinyspeck.slackmacgap")
            )
            XCTAssertEqual(
                model.disabledAppRules.map(\.bundleIdentifier),
                ["com.tinyspeck.slackmacgap"]
            )
        }
    }

    func test_snapshotPublisher_emitsWhenDisabledAppRulesChange() {
        let expectation = expectation(description: "snapshot emits after app rule changes")
        var cancellables = Set<AnyCancellable>()

        runOnMainActor {
            let model = makeModel()

            model.snapshotPublisher
                .dropFirst()
                .sink { snapshot in
                    XCTAssertTrue(snapshot.disabledAppBundleIdentifiers.contains("com.apple.Safari"))
                    expectation.fulfill()
                }
                .store(in: &cancellables)

            model.disableApplication(
                bundleIdentifier: "com.apple.Safari",
                displayName: "Safari"
            )
        }

        wait(for: [expectation], timeout: 1.0)
        _ = cancellables
    }

    func test_clipboardContextEnabled_defaultsToFalseAndPersists() {
        runOnMainActor {
            let userDefaults = makeUserDefaults()
            let model = makeModel(userDefaults: userDefaults)

            XCTAssertFalse(model.isClipboardContextEnabled)
            XCTAssertFalse(model.snapshot.isClipboardContextEnabled)

            model.setClipboardContextEnabled(true)
            let reloadedModel = makeModel(userDefaults: userDefaults)

            XCTAssertTrue(reloadedModel.isClipboardContextEnabled)
            XCTAssertTrue(reloadedModel.snapshot.isClipboardContextEnabled)
        }
    }

    func test_snapshotPublisher_emitsWhenClipboardContextSettingChanges() {
        let expectation = expectation(description: "snapshot emits after clipboard setting changes")
        var cancellables = Set<AnyCancellable>()

        runOnMainActor {
            let model = makeModel()

            model.snapshotPublisher
                .dropFirst()
                .sink { snapshot in
                    XCTAssertTrue(snapshot.isClipboardContextEnabled)
                    expectation.fulfill()
                }
                .store(in: &cancellables)

            model.setClipboardContextEnabled(true)
        }

        wait(for: [expectation], timeout: 1.0)
        _ = cancellables
    }

    func test_fastMode_defaultsToFalseAndPersists() {
        runOnMainActor {
            let userDefaults = makeUserDefaults()
            let model = makeModel(userDefaults: userDefaults)

            XCTAssertFalse(model.isFastModeEnabled)
            XCTAssertFalse(model.snapshot.isFastModeEnabled)

            model.setFastModeEnabled(true)
            let reloadedModel = makeModel(userDefaults: userDefaults)

            XCTAssertTrue(reloadedModel.isFastModeEnabled)
            XCTAssertTrue(reloadedModel.snapshot.isFastModeEnabled)
        }
    }

    func test_snapshotPublisher_emitsWhenFastModeSettingChanges() {
        let expectation = expectation(description: "snapshot emits after fast mode setting changes")
        var cancellables = Set<AnyCancellable>()

        runOnMainActor {
            let model = makeModel()

            model.snapshotPublisher
                .dropFirst()
                .sink { snapshot in
                    XCTAssertTrue(snapshot.isFastModeEnabled)
                    expectation.fulfill()
                }
                .store(in: &cancellables)

            model.setFastModeEnabled(true)
        }

        wait(for: [expectation], timeout: 1.0)
        _ = cancellables
    }

    func test_mirrorPreference_defaultsToAutoAndPersists() {
        runOnMainActor {
            let userDefaults = makeUserDefaults()
            let model = makeModel(userDefaults: userDefaults)

            XCTAssertEqual(model.mirrorPreference, .auto)
            XCTAssertEqual(model.snapshot.mirrorPreference, .auto)

            model.setMirrorPreference(.alwaysMirror)
            let reloadedModel = makeModel(userDefaults: userDefaults)

            XCTAssertEqual(reloadedModel.mirrorPreference, .alwaysMirror)
            XCTAssertEqual(reloadedModel.snapshot.mirrorPreference, .alwaysMirror)
        }
    }

    func test_snapshotPublisher_emitsWhenMirrorPreferenceChanges() {
        let expectation = expectation(description: "snapshot emits after mirror preference changes")
        var cancellables = Set<AnyCancellable>()

        runOnMainActor {
            let model = makeModel()

            model.snapshotPublisher
                .dropFirst()
                .sink { snapshot in
                    XCTAssertEqual(snapshot.mirrorPreference, .alwaysInline)
                    expectation.fulfill()
                }
                .store(in: &cancellables)

            model.setMirrorPreference(.alwaysInline)
        }

        wait(for: [expectation], timeout: 1.0)
        _ = cancellables
    }

    func test_acceptanceHint_defaultsToOnAndShowsWordAcceptLabel() {
        runOnMainActor {
            let model = makeModel()

            XCTAssertTrue(model.showAcceptanceHint)
            XCTAssertEqual(model.acceptanceHintLabel, SuggestionSettingsModel.defaultAcceptanceKeyLabel)
        }
    }

    func test_showAcceptanceHint_persistsAcrossModelRecreation() {
        runOnMainActor {
            let userDefaults = makeUserDefaults()
            let model = makeModel(userDefaults: userDefaults)

            model.setShowAcceptanceHint(false)
            let reloadedModel = makeModel(userDefaults: userDefaults)

            XCTAssertFalse(reloadedModel.showAcceptanceHint)
            XCTAssertNil(reloadedModel.acceptanceHintLabel, "Disabled hint should resolve to no label")
        }
    }

    func test_acceptanceHintLabel_tracksRebindAndFallsBackWhenWordAcceptCleared() {
        runOnMainActor {
            let model = makeModel()

            model.setAcceptanceKey(keyCode: 49, modifiers: [], label: "Space")
            XCTAssertEqual(model.acceptanceHintLabel, "Space", "Hint should follow the rebound word-accept key")

            // Clearing word-accept should fall back to the still-bound full-accept key.
            model.clearAcceptanceKey()
            XCTAssertEqual(model.acceptanceHintLabel, model.fullAcceptanceKeyLabel)

            // With no accept key bound at all, there is nothing to teach.
            model.clearFullAcceptanceKey()
            XCTAssertNil(model.acceptanceHintLabel)
        }
    }

    func test_emojiPickerAcceptKeyLabel_ignoresGhostHintToggleAndRequiresWordAccept() {
        runOnMainActor {
            let model = makeModel()

            model.setShowAcceptanceHint(false)
            XCTAssertEqual(model.emojiPickerAcceptKeyLabel, SuggestionSettingsModel.defaultAcceptanceKeyLabel)

            model.clearAcceptanceKey()
            XCTAssertNil(model.emojiPickerAcceptKeyLabel)
        }
    }

    @MainActor
    private func makeModel(
        userDefaults: UserDefaults? = nil
    ) -> SuggestionSettingsModel {
        let model = SuggestionSettingsModel(
            configuration: .standard,
            userDefaults: userDefaults ?? makeUserDefaults()
        )
        Self.retainedModels.append(model)
        return model
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "SuggestionSettingsModelDisabledAppsTests-\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected an isolated UserDefaults suite")
            return .standard
        }

        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaultsSuites.append((suiteName: suiteName, userDefaults: userDefaults))
        return userDefaults
    }

    /// `MainActor.assumeIsolated` lets the compiler treat the closure as main-actor bound once we
    /// have synchronously hopped to the main thread. This keeps the tests deterministic without
    /// wrapping each case in a Swift concurrency task, which is the teardown path that was
    /// crashing during hosted test execution.
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
}
