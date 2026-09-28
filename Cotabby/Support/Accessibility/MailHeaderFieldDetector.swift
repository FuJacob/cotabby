import ApplicationServices
import Foundation

/// File overview:
/// Recognizes the address and subject fields of a Mail compose window, where Cotabby stands down.
///
/// Why: Cotabby accepts a suggestion with Tab, and Tab is how a writer moves from To to Cc to
/// Subject to the body. Measured 2026-09-10 in a live compose window: the model offered " is the
/// email address of the user." after a typed address and "." after a subject, the Tab meant to
/// move on inserted them instead, and the next field's text landed in the same field. Nothing a
/// writer wants completed lives in those fields (addresses come from Mail's own contact
/// completion), so the whole header is left to Mail. Pure: the resolver reads the identifier and
/// asks here.
enum MailHeaderFieldDetector {
    static let mailBundleIdentifier = "com.apple.mail"

    /// Accessibility identifiers Mail sets on its compose header fields (read live with the AX
    /// inspector: `Mail.toField`, `Mail.ccField`, `Mail.subjectField`; the others follow the same
    /// naming for the optional header rows).
    static let headerFieldIdentifiers: Set<String> = [
        "Mail.toField", "Mail.ccField", "Mail.bccField", "Mail.subjectField", "Mail.replyToField", "Mail.fromField"
    ]

    static let blockedReason = "Mail's address and subject fields are left to Mail; Tab moves to the next field there."

    /// Cheap pre-check so the identifier is only fetched for Mail's own text fields.
    static func mightBeHeaderField(bundleIdentifier: String, role: String) -> Bool {
        bundleIdentifier == mailBundleIdentifier && role == kAXTextFieldRole as String
    }

    static func isHeaderField(bundleIdentifier: String, role: String, accessibilityIdentifier: String?) -> Bool {
        guard mightBeHeaderField(bundleIdentifier: bundleIdentifier, role: role), let accessibilityIdentifier else {
            return false
        }
        return headerFieldIdentifiers.contains(accessibilityIdentifier)
    }
}
