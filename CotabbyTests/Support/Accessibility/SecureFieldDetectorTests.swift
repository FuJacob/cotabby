import XCTest
@testable import Cotabby

/// Tests for the pure sensitive-field policy. Suppression is the safe default, so the cases lean
/// toward confirming that secrets are caught (including the role-description-only NSSecureTextField
/// case the previous inline check missed) without over-matching obviously benign fields.
final class SecureFieldDetectorTests: XCTestCase {
    func test_isSecure_falseForPlainTextField() {
        XCTAssertFalse(SecureFieldDetector.isSecure(
            role: "AXTextField", subrole: nil, roleDescription: "text field",
            title: "Email", descriptionLabel: nil))
    }

    func test_isSecure_detectsSecureTextFieldViaRoleDescriptionOnly() {
        XCTAssertTrue(SecureFieldDetector.isSecure(
            role: "AXTextField", subrole: nil, roleDescription: "secure text field",
            title: nil, descriptionLabel: nil))
    }

    func test_isSecure_detectsPasswordByDescription() {
        XCTAssertTrue(SecureFieldDetector.isSecure(
            role: "AXTextField", subrole: nil, roleDescription: "text field",
            title: nil, descriptionLabel: "Password"))
    }

    func test_isSecure_detectsNonPasswordSecretsByLabel() {
        for label in ["CVV", "Security code", "Verification code", "One-time code", "Card number"] {
            XCTAssertTrue(
                SecureFieldDetector.isSecure(
                    role: "AXTextField", subrole: nil, roleDescription: nil,
                    title: label, descriptionLabel: nil),
                "Expected \(label) to be treated as sensitive")
        }
    }

    func test_isSecure_isCaseInsensitive() {
        XCTAssertTrue(SecureFieldDetector.isSecure(
            role: nil, subrole: nil, roleDescription: nil, title: "PASSWORD", descriptionLabel: nil))
    }

    func test_isSecure_ignoresNilAndEmptyMarkers() {
        XCTAssertFalse(SecureFieldDetector.isSecure(
            role: "", subrole: nil, roleDescription: "", title: nil, descriptionLabel: ""))
    }

    func test_isSecure_falseForUnrelatedSearchField() {
        XCTAssertFalse(SecureFieldDetector.isSecure(
            role: "AXTextField", subrole: nil, roleDescription: "text field",
            title: "Search", descriptionLabel: "Type to search"))
    }
}
