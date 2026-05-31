import XCTest
@testable import Cotabby

/// Tests the pure presentation logic of `LaunchAtLoginState` — the flags the General settings row
/// uses to decide the toggle position, whether it is interactive, and what explanatory copy to show.
/// The OS registration itself (`SMAppService`) is not exercised here; only the state mapping is.
final class LaunchAtLoginStateTests: XCTestCase {
    func testIsEnabledOnlyForEnabled() {
        XCTAssertTrue(LaunchAtLoginState.enabled.isEnabled)
        XCTAssertFalse(LaunchAtLoginState.disabled.isEnabled)
        XCTAssertFalse(LaunchAtLoginState.requiresApproval.isEnabled)
        XCTAssertFalse(LaunchAtLoginState.unavailable("x").isEnabled)
    }

    func testCanToggleForEveryStateExceptUnavailable() {
        XCTAssertTrue(LaunchAtLoginState.enabled.canToggle)
        XCTAssertTrue(LaunchAtLoginState.disabled.canToggle)
        XCTAssertTrue(LaunchAtLoginState.requiresApproval.canToggle)
        XCTAssertFalse(LaunchAtLoginState.unavailable("x").canToggle)
    }

    func testDetailOnlyForNonTrivialStates() {
        XCTAssertNil(LaunchAtLoginState.enabled.detail)
        XCTAssertNil(LaunchAtLoginState.disabled.detail)
        XCTAssertNotNil(LaunchAtLoginState.requiresApproval.detail)
        XCTAssertEqual(LaunchAtLoginState.unavailable("Move me").detail, "Move me")
    }
}
