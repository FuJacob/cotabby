import ApplicationServices
import Foundation

/// File overview:
/// Recognizes sign-in and verification fields (email, username, phone, one-time codes, card
/// numbers) where Cotabby stands down, alongside password fields, which arrive as secure fields
/// and are already blocked by the resolver.
///
/// Why: a completion in "Email or phone" guesses at the user's identity. Accepting one types a
/// wrong address into a login form, and showing one paints a guessed address beside the real one.
/// Nothing in such a field is prose a writer wants continued. Browsers mark only passwords as
/// secure, so these fields are recognized from what the page says about them: its label (title,
/// description, placeholder) and its DOM id, plus the typed text itself looking like an address.
///
/// Scope: single-line fields only (text fields and combo boxes). A multi-line field labelled
/// "email" is an email *body*, which is exactly where completions belong. Pure: the resolver reads
/// the attributes and asks here.
enum CredentialFieldDetector {
    static let blockedReason = "Sign-in and verification fields are left alone."

    /// Words in a field's label that name a credential or verification input, matched as whole
    /// words in the lowercased label ("pin" matches "Enter PIN", not "shipping").
    static let labelKeywords: [String] = [
        "email", "e-mail", "username", "user name", "user id", "userid", "login", "log in", "sign in",
        "phone", "mobile number", "password", "passcode", "pin", "one-time", "one time code",
        "verification code", "security code", "otp", "2fa", "two-factor", "authentication code",
        "card number", "cvc", "cvv", "expiry", "expiration"
    ]

    /// DOM ids used by common sign-in forms (Google's `identifierId`, and the generic names).
    static let identifierKeywords: [String] = [
        "identifierid", "username", "userid", "email", "login", "passwd", "password", "otp", "totp", "phone"
    ]

    /// Cheap pre-check so labels are only fetched for single-line fields.
    static func mightBeCredentialField(role: String) -> Bool {
        role == kAXTextFieldRole as String || role == kAXComboBoxRole as String
    }

    static func isCredentialField(
        role: String,
        labels: [String?],
        domIdentifier: String?,
        text: String?
    ) -> Bool {
        guard mightBeCredentialField(role: role) else { return false }

        for label in labels.compactMap({ $0?.lowercased() }) where !label.isEmpty {
            if labelKeywords.contains(where: { containsWord($0, in: label) }) {
                return true
            }
        }

        if let id = domIdentifier?.lowercased(), !id.isEmpty,
           identifierKeywords.contains(where: { id.contains($0) }) {
            return true
        }

        return looksLikeEmailAddress(text)
    }

    /// The whole value is one address-shaped token ("name@domain.tld"), as typed into a login box.
    static func looksLikeEmailAddress(_ text: String?) -> Bool {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return false }
        return text.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    /// `keyword` appears in `label` with no letter or digit directly before or after it, so "pin"
    /// matches "Enter PIN" but not "shipping".
    private static func containsWord(_ keyword: String, in label: String) -> Bool {
        var searchRange = label.startIndex..<label.endIndex
        while let found = label.range(of: keyword, range: searchRange) {
            let before = found.lowerBound == label.startIndex ? nil : label[label.index(before: found.lowerBound)]
            let after = found.upperBound == label.endIndex ? nil : label[found.upperBound]
            let isBoundary: (Character?) -> Bool = { $0.map { !$0.isLetter && !$0.isNumber } ?? true }
            if isBoundary(before) && isBoundary(after) {
                return true
            }
            searchRange = found.upperBound..<label.endIndex
        }
        return false
    }
}
