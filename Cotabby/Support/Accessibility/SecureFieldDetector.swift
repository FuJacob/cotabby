import Foundation

/// File overview:
/// Pure classification of whether a focused field is sensitive enough that Cotabby must never
/// generate a suggestion for it (passwords, card numbers, security/verification codes, ...). Kept
/// pure and string-only so the policy is unit-testable without a live Accessibility element: the
/// resolver reads a few AX markers and hands the strings here.
///
/// Why this exists:
/// The previous inline check looked only at the role, subrole, `AXDescription`, and `AXTitle` for the
/// substrings "secure" / "password". That missed two common cases: a native `NSSecureTextField`,
/// which announces its sensitivity through the *role description* ("secure text field") rather than
/// the description; and fields labelled for other secrets (CVV, security code, one-time code) that
/// never contain the literal word "password". Suppressing in a non-sensitive field only costs a
/// missed suggestion, so the marker set deliberately errs toward caution.
enum SecureFieldDetector {
    /// True when any supplied Accessibility marker indicates a sensitive field. Every marker is
    /// optional so the caller can pass whatever it managed to read; nil and empty markers are ignored.
    /// Matching is case-insensitive substring containment, which is why a role description of
    /// "secure text field" trips the "secure" marker.
    static func isSecure(
        role: String?,
        subrole: String?,
        roleDescription: String?,
        title: String?,
        descriptionLabel: String?
    ) -> Bool {
        let markers = [role, subrole, roleDescription, title, descriptionLabel]
            .compactMap { $0?.lowercased() }
            .filter { !$0.isEmpty }
        return markers.contains { marker in
            sensitiveMarkers.contains { marker.contains($0) }
        }
    }

    /// Substrings that mark a field sensitive when they appear in any of its markers. Lowercased for
    /// case-insensitive containment. Intentionally broad: a false positive only suppresses a
    /// suggestion, while a false negative could surface a secret as ghost text. "secure" is kept from
    /// the original check (it also catches the `NSSecureTextField` role description); the rest cover
    /// the common non-password secrets that never contain the word "password".
    static let sensitiveMarkers: [String] = [
        "secure",
        "password",
        "passcode",
        "passphrase",
        "cvv",
        "cvc",
        "security code",
        "verification code",
        "one-time code",
        "one time code",
        "social security",
        "card number",
        "credit card"
    ]
}
