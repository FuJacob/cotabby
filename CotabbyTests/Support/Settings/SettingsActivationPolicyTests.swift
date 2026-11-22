import AppKit
import XCTest
@testable import Cotabby

/// Pins the Settings window to the Dock/Command-Tab presence rule: visible in the switcher while
/// Settings exists, background-only otherwise. A minimized window still counts as open, which is why
/// the input is "window exists" rather than "window is visible".
final class SettingsActivationPolicyTests: XCTestCase {
    func test_openSettingsWindowPromotesToRegular() {
        XCTAssertEqual(SettingsActivationPolicy.policy(isSettingsWindowOpen: true), .regular)
    }

    func test_closedSettingsWindowReturnsToAccessory() {
        XCTAssertEqual(SettingsActivationPolicy.policy(isSettingsWindowOpen: false), .accessory)
    }
}
