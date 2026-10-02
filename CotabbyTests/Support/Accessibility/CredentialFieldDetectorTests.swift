import ApplicationServices
import XCTest
@testable import Cotabby

final class CredentialFieldDetectorTests: XCTestCase {
    private let textField = kAXTextFieldRole as String

    func test_googleSignInFieldIsBlocked() {
        XCTAssertTrue(CredentialFieldDetector.isCredentialField(
            role: textField, labels: ["Email or phone", nil, nil], domIdentifier: "identifierId", text: "realdeepdark"
        ))
        XCTAssertTrue(CredentialFieldDetector.isCredentialField(
            role: textField, labels: [nil, nil, nil], domIdentifier: "identifierId", text: ""
        ))
    }

    func test_commonLabelsAreBlocked() {
        for label in ["Username", "Enter PIN", "Verification code", "Phone number", "Card number", "Log in"] {
            XCTAssertTrue(
                CredentialFieldDetector.isCredentialField(role: textField, labels: [label], domIdentifier: nil, text: nil),
                label
            )
        }
    }

    func test_typedAddressIsBlockedEvenWithoutLabel() {
        XCTAssertTrue(CredentialFieldDetector.isCredentialField(
            role: textField, labels: [], domIdentifier: nil, text: "senad@imperum.io"
        ))
        XCTAssertFalse(CredentialFieldDetector.looksLikeEmailAddress("mail senad@imperum.io today"))
    }

    func test_ordinaryFieldsAreNotBlocked() {
        XCTAssertFalse(CredentialFieldDetector.isCredentialField(
            role: textField, labels: ["Shipping notes", "Type a message", "Search"], domIdentifier: "q", text: "hello there"
        ))
        XCTAssertFalse(CredentialFieldDetector.isCredentialField(
            role: textField, labels: ["Spinning"], domIdentifier: nil, text: nil
        ))
    }

    func test_multiLineFieldsAreNeverBlocked() {
        XCTAssertFalse(CredentialFieldDetector.isCredentialField(
            role: kAXTextAreaRole as String, labels: ["Email body"], domIdentifier: "email", text: "a@b.co"
        ))
    }
}
