import XCTest
@testable import Cotabby

/// Locks the recovery matrix independently of AppKit so future lifecycle edits cannot strand a
/// user with both the status item and Settings hidden, or make Settings appear at every login.
@MainActor
final class MenuBarRecoveryPolicyTests: XCTestCase {
    func test_manualColdLaunchWithHiddenIconShowsSettings() {
        XCTAssertTrue(
            MenuBarRecoveryPolicy.shouldShowSettingsOnColdLaunch(
                isMenuBarIconVisible: false,
                wasLaunchedAtLogin: false,
                wasSettingsExplicitlyRequested: false
            )
        )
    }

    func test_loginLaunchWithHiddenIconStaysInBackground() {
        XCTAssertFalse(
            MenuBarRecoveryPolicy.shouldShowSettingsOnColdLaunch(
                isMenuBarIconVisible: false,
                wasLaunchedAtLogin: true,
                wasSettingsExplicitlyRequested: false
            )
        )
    }

    func test_visibleIconDoesNotNeedColdLaunchRecovery() {
        XCTAssertFalse(
            MenuBarRecoveryPolicy.shouldShowSettingsOnColdLaunch(
                isMenuBarIconVisible: true,
                wasLaunchedAtLogin: false,
                wasSettingsExplicitlyRequested: false
            )
        )
    }

    func test_explicitSettingsRequestOverridesLaunchContext() {
        XCTAssertTrue(
            MenuBarRecoveryPolicy.shouldShowSettingsOnColdLaunch(
                isMenuBarIconVisible: true,
                wasLaunchedAtLogin: true,
                wasSettingsExplicitlyRequested: true
            )
        )
    }

    func test_reopenWithVisibleIconUsesNormalAppKitHandling() {
        XCTAssertTrue(
            MenuBarRecoveryPolicy.shouldLetAppKitHandleReopen(
                isMenuBarIconVisible: true,
                hasVisibleWindows: false,
                isSettingsWindowOpen: false
            )
        )
    }

    func test_reopenWithHiddenIconAndVisibleSettingsUsesNormalAppKitHandling() {
        XCTAssertTrue(
            MenuBarRecoveryPolicy.shouldLetAppKitHandleReopen(
                isMenuBarIconVisible: false,
                hasVisibleWindows: true,
                isSettingsWindowOpen: true
            )
        )
    }

    func test_reopenWithHiddenIconAndNoVisibleWindowRequiresCustomRecovery() {
        XCTAssertFalse(
            MenuBarRecoveryPolicy.shouldLetAppKitHandleReopen(
                isMenuBarIconVisible: false,
                hasVisibleWindows: false,
                isSettingsWindowOpen: false
            )
        )
    }

    func test_reopenWithDifferentVisibleWindowStillRequiresSettingsRecovery() {
        XCTAssertFalse(
            MenuBarRecoveryPolicy.shouldLetAppKitHandleReopen(
                isMenuBarIconVisible: false,
                hasVisibleWindows: true,
                isSettingsWindowOpen: false
            )
        )
    }
}
