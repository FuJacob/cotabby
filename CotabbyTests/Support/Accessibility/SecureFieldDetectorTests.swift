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

    func test_isSecure_detectsNativeSecureTextFieldSubrole() {
        XCTAssertTrue(SecureFieldDetector.isSecure(
            role: "AXTextField", subrole: "AXSecureTextField", roleDescription: nil,
            title: nil, descriptionLabel: nil))
    }

    func test_isSecure_everyMarkerTripsInAnyMarkerPosition() {
        // Each marker is embedded mid-label to prove substring containment, and tried in every
        // attribute slot because the resolver passes whatever it managed to read.
        for marker in SecureFieldDetector.sensitiveMarkers {
            let label = "Enter \(marker) here"
            let slots: [(String, Bool)] = [
                ("role", SecureFieldDetector.isSecure(role: label, subrole: nil, roleDescription: nil, title: nil, descriptionLabel: nil)),
                ("subrole", SecureFieldDetector.isSecure(role: nil, subrole: label, roleDescription: nil, title: nil, descriptionLabel: nil)),
                ("roleDescription", SecureFieldDetector.isSecure(role: nil, subrole: nil, roleDescription: label, title: nil, descriptionLabel: nil)),
                ("title", SecureFieldDetector.isSecure(role: nil, subrole: nil, roleDescription: nil, title: label, descriptionLabel: nil)),
                ("descriptionLabel", SecureFieldDetector.isSecure(role: nil, subrole: nil, roleDescription: nil, title: nil, descriptionLabel: label))
            ]
            for (slot, isSecure) in slots {
                XCTAssertTrue(isSecure, "\(marker) in \(slot)")
            }
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
