import XCTest
@testable import Cotabby

/// Locks the recovery matrix independently of AppKit so future lifecycle edits cannot strand a
/// user with both the status item and Settings hidden, or make Settings appear at every login.
/// Each policy's boolean inputs are small enough to pin both truth tables exhaustively.
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

    /// An existing Settings window is always restored by Cotabby itself (even when the status item
    /// is visible), the status item alone lets AppKit handle reopen, and with neither available
    /// Cotabby opens Settings so the reopen has a visible response.
    func test_reopenAction_truthTable() {
        let cases: [(iconVisible: Bool, settingsOpen: Bool, expected: MenuBarRecoveryPolicy.ReopenAction)] = [
            (true, false, .letAppKitHandle),
            (true, true, .focusExistingSettings),
            (false, true, .focusExistingSettings),
            (false, false, .openSettingsForRecovery)
        ]
        for testCase in cases {
            XCTAssertEqual(
                MenuBarRecoveryPolicy.reopenAction(
                    isMenuBarIconVisible: testCase.iconVisible,
                    isSettingsWindowOpen: testCase.settingsOpen
                ),
                testCase.expected,
                "icon=\(testCase.iconVisible) settings=\(testCase.settingsOpen)"
            )
        }
    }
}
