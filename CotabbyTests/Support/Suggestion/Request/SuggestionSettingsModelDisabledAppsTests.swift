import Combine
import CoreGraphics
import XCTest
@testable import Cotabby

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
