import ApplicationServices
import XCTest
@testable import Cotabby

final class MailHeaderFieldDetectorTests: XCTestCase {
    private let textField = kAXTextFieldRole as String

    func test_mailComposeHeaderFieldsAreRecognizedByIdentifier() {
        for identifier in ["Mail.toField", "Mail.ccField", "Mail.bccField", "Mail.subjectField"] {
            XCTAssertTrue(
                MailHeaderFieldDetector.isHeaderField(bundleIdentifier: "com.apple.mail", role: textField, accessibilityIdentifier: identifier),
                identifier
            )
        }
    }

    func test_bodyOtherAppsAndUnknownFieldsAreNot() {
        // The body is an AXWebArea with no identifier; a search field is a text field with another.
        XCTAssertFalse(MailHeaderFieldDetector.isHeaderField(bundleIdentifier: "com.apple.mail", role: "AXWebArea", accessibilityIdentifier: nil))
        XCTAssertFalse(MailHeaderFieldDetector.isHeaderField(bundleIdentifier: "com.apple.mail", role: textField, accessibilityIdentifier: "Mail.searchField"))
        XCTAssertFalse(MailHeaderFieldDetector.isHeaderField(bundleIdentifier: "com.apple.mail", role: textField, accessibilityIdentifier: nil))
        XCTAssertFalse(MailHeaderFieldDetector.isHeaderField(bundleIdentifier: "com.google.Chrome", role: textField, accessibilityIdentifier: "Mail.toField"))
    }

    func test_theIdentifierIsOnlyWorthFetchingForMailTextFields() {
        XCTAssertTrue(MailHeaderFieldDetector.mightBeHeaderField(bundleIdentifier: "com.apple.mail", role: textField))
        XCTAssertFalse(MailHeaderFieldDetector.mightBeHeaderField(bundleIdentifier: "com.apple.mail", role: "AXWebArea"))
        XCTAssertFalse(MailHeaderFieldDetector.mightBeHeaderField(bundleIdentifier: "com.apple.Notes", role: textField))
    }
}
