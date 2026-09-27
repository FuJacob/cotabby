import XCTest
@testable import Cotabby

/// Locks the recovery matrix independently of AppKit so future lifecycle edits cannot strand a
/// user with both the status item and Settings hidden, or make Settings appear at every login.
/// Each policy has three boolean inputs, so both truth tables are pinned exhaustively.
@MainActor
final class MenuBarRecoveryPolicyTests: XCTestCase {
    /// Manual launches with a hidden icon recover through Settings; login launches stay in the
    /// background; an explicit Settings request always wins.
    func test_shouldShowSettingsOnColdLaunch_truthTable() {
        let cases: [(iconVisible: Bool, atLogin: Bool, requested: Bool, expected: Bool)] = [
            (false, false, false, true),
            (false, true, false, false),
            (true, false, false, false),
            (true, true, false, false),
            (false, false, true, true),
            (false, true, true, true),
            (true, false, true, true),
            (true, true, true, true)
        ]
        for testCase in cases {
            XCTAssertEqual(
                MenuBarRecoveryPolicy.shouldShowSettingsOnColdLaunch(
                    isMenuBarIconVisible: testCase.iconVisible,
                    wasLaunchedAtLogin: testCase.atLogin,
                    wasSettingsExplicitlyRequested: testCase.requested
                ),
                testCase.expected,
                "icon=\(testCase.iconVisible) login=\(testCase.atLogin) requested=\(testCase.requested)"
            )
        }
    }

    /// AppKit handles reopen when the status item is visible, or when a visible window is the
    /// Settings window it can restore. A hidden icon with no windows, a non-Settings window, or a
    /// Settings window that is not visible needs Cotabby's own recovery.
    func test_shouldLetAppKitHandleReopen_truthTable() {
        let cases: [(iconVisible: Bool, visibleWindows: Bool, settingsOpen: Bool, expected: Bool)] = [
            (true, false, false, true),
            (true, true, false, true),
            (true, false, true, true),
            (true, true, true, true),
            (false, true, true, true),
            (false, false, false, false),
            (false, true, false, false),
            (false, false, true, false)
        ]
        for testCase in cases {
            XCTAssertEqual(
                MenuBarRecoveryPolicy.shouldLetAppKitHandleReopen(
                    isMenuBarIconVisible: testCase.iconVisible,
                    hasVisibleWindows: testCase.visibleWindows,
                    isSettingsWindowOpen: testCase.settingsOpen
                ),
                testCase.expected,
                "icon=\(testCase.iconVisible) windows=\(testCase.visibleWindows) settings=\(testCase.settingsOpen)"
            )
        }
    }
}
