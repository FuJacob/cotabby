import XCTest
@testable import Cotabby

final class SystemUIFocusShadowPolicyTests: XCTestCase {
    func testPrivacyPromptOwningFocusYieldsToFrontmostApp() {
        XCTAssertTrue(
            SystemUIFocusShadowPolicy.shouldPreferFrontmostApplication(
                owningBundleIdentifier: "com.apple.UserNotificationCenter",
                frontmostBundleIdentifier: "com.apple.TextEdit"
            )
        )
    }

    func testAccessoryLaunchersKeepTheirFocus() {
        XCTAssertFalse(
            SystemUIFocusShadowPolicy.shouldPreferFrontmostApplication(
                owningBundleIdentifier: "com.raycast.macos",
                frontmostBundleIdentifier: "com.apple.TextEdit"
            )
        )
    }

    func testAgentThatIsItselfFrontmostIsNotShadowed() {
        XCTAssertFalse(
            SystemUIFocusShadowPolicy.shouldPreferFrontmostApplication(
                owningBundleIdentifier: "com.apple.UserNotificationCenter",
                frontmostBundleIdentifier: "com.apple.UserNotificationCenter"
            )
        )
    }

    func testMissingIdentitiesNeverShadow() {
        XCTAssertFalse(SystemUIFocusShadowPolicy.shouldPreferFrontmostApplication(owningBundleIdentifier: nil, frontmostBundleIdentifier: "a"))
        XCTAssertFalse(SystemUIFocusShadowPolicy.shouldPreferFrontmostApplication(owningBundleIdentifier: "com.apple.controlcenter", frontmostBundleIdentifier: nil))
    }
}
