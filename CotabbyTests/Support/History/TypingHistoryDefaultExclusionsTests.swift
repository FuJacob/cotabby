import XCTest
@testable import Cotabby

/// Locks the built-in recording exclusions: the verified password-manager bundle identifiers are
/// excluded, ordinary writing apps are not, and matching is exact.
final class TypingHistoryDefaultExclusionsTests: XCTestCase {
    func test_passwordManagersAreExcluded() {
        for identifier in [
            "com.1password.1password",
            "com.bitwarden.desktop",
            "org.keepassxc.keepassxc",
            "com.hicknhacksoftware.MacPass",
            "com.nordsec.nordpass",
            "me.proton.pass.electron",
            "com.apple.Passwords",
            "com.apple.keychainaccess"
        ] {
            XCTAssertTrue(TypingHistoryDefaultExclusions.isExcluded(bundleIdentifier: identifier), identifier)
        }
    }

    func test_writingAppsAreNotExcluded() {
        for identifier in ["com.apple.mail", "com.apple.Notes", "com.google.Chrome", "com.tinyspeck.slackmacgap"] {
            XCTAssertFalse(TypingHistoryDefaultExclusions.isExcluded(bundleIdentifier: identifier), identifier)
        }
    }

    func test_matchingIsExact() {
        XCTAssertFalse(TypingHistoryDefaultExclusions.isExcluded(bundleIdentifier: "com.1password"))
        XCTAssertFalse(TypingHistoryDefaultExclusions.isExcluded(bundleIdentifier: "com.bitwarden.desktop.helper"))
    }
}
