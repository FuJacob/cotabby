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

    func test_comboBoxSignInFieldIsBlocked() {
        XCTAssertTrue(CredentialFieldDetector.isCredentialField(
            role: kAXComboBoxRole as String, labels: ["Email address"], domIdentifier: nil, text: nil
        ))
    }

    func test_labelsAboutEmailWritingAreNotBlocked() {
        for label in ["Email subject", "Email preview text", "Search email", "Message to phone"] {
            XCTAssertFalse(
                CredentialFieldDetector.isCredentialField(role: textField, labels: [label], domIdentifier: nil, text: nil),
                label
            )
        }
    }

    func test_signInDomIdentifiersAreBlocked() {
        let identifiers = [
            "username", "email", "passwd", "otp", "login_field", "user_login", "user_email", "loginEmail",
            "txtUserName", "phoneNumber", "phonenumber", "emailaddress", "otp-3", "OTPCode", "one-time-code"
        ]
        for identifier in identifiers {
            XCTAssertTrue(CredentialFieldDetector.domIdentifierNamesCredential(identifier), identifier)
        }
    }

    func test_domIdentifiersThatOnlyContainACredentialWordAreNotBlocked() {
        let identifiers = [
            "phonebook-search", "emailSearch", "email-subject", "userInput", "shipping", "mailbox", "identifier", "q", ""
        ]
        for identifier in identifiers {
            XCTAssertFalse(CredentialFieldDetector.domIdentifierNamesCredential(identifier), identifier)
            XCTAssertFalse(
                CredentialFieldDetector.isCredentialField(
                    role: textField, labels: ["Search"], domIdentifier: identifier, text: "hello"
                ),
                identifier
            )
        }
    }

    func test_typedAddressIsBlockedEvenWithoutLabel() {
        XCTAssertTrue(CredentialFieldDetector.isCredentialField(
            role: textField, labels: [], domIdentifier: nil, text: "senad@imperum.io"
        ))
        XCTAssertFalse(CredentialFieldDetector.looksLikeAddressEntry("mail senad@imperum.io today"))
    }

    func test_addressBeingTypedIsBlockedBeforeItIsComplete() {
        // A neutral "Account" box with a neutral id: only the typed text gives it away.
        for text in ["alice@", "alice@gm", "alice@gmail.com"] {
            XCTAssertTrue(
                CredentialFieldDetector.isCredentialField(
                    role: textField, labels: ["Account"], domIdentifier: "identifier", text: text
                ),
                text
            )
        }
        for text in ["@alice", "alice", "medium.com/@alice", "ping alice@", "a@b@c"] {
            XCTAssertFalse(CredentialFieldDetector.looksLikeAddressEntry(text), text)
        }
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
        XCTAssertFalse(CredentialFieldDetector.mightBeCredentialField(role: kAXTextAreaRole as String))
    }
}
