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
///
/// The verdict has two halves because they cost differently. The role pair is read on every poll
/// anyway, so `isSecureRole` is re-judged each poll and notices a field that turns secure in place.
/// The label half (`hasSecureLabel`) needs three more AX round trips, so the resolver caches it for
/// the focus session.
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
        isSecureRole(role: role, subrole: subrole)
            || hasSecureLabel(roleDescription: roleDescription, title: title, descriptionLabel: descriptionLabel)
    }

    /// The role half: `AXSecureTextField` (native secure fields and every browser's
    /// `type=password` input) or any other sensitive marker in the role pair.
    static func isSecureRole(role: String?, subrole: String?) -> Bool {
        containsSensitiveMarker([role, subrole])
    }

    /// The label half: a sensitive marker in the role description, title or description, or a title
    /// or description that names a secret in another language or by name (`labelNamesSecret`).
    static func hasSecureLabel(roleDescription: String?, title: String?, descriptionLabel: String?) -> Bool {
        containsSensitiveMarker([roleDescription, title, descriptionLabel])
            || [title, descriptionLabel].contains { $0.map(labelNamesSecret) ?? false }
    }

    private static func containsSensitiveMarker(_ markers: [String?]) -> Bool {
        markers
            .compactMap { $0?.lowercased() }
            .filter { !$0.isEmpty }
            .contains { marker in sensitiveMarkers.contains { marker.contains($0) } }
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

    /// Localized words for "password" that are matched anywhere in a label, case- and
    /// diacritic-insensitively. Each is specific enough not to occur inside an unrelated word, and
    /// several languages build compounds around it ("Passwortbestätigung", "lösenordet"). Scripts
    /// written without spaces, or with prefixes attached to the word (Hebrew, Arabic), cannot be
    /// split into words at all. Italian uses "password", already a sensitive marker.
    static let secretLabelSubstrings: [String] = [
        "passwort", "kennwort",
        "mot de passe",
        "contraseña",
        "wachtwoord",
        "lösenord",
        "adgangskode",
        "passord",
        "パスワード",
        "密码", "密碼",
        "비밀번호",
        "كلمة المرور",
        "סיסמה"
    ]

    /// Terms that must start a word but may run on into a suffix: plurals ("API keys") and the
    /// endings Turkish, Polish and Russian attach ("Şifrenizi", "hasła", "пароля"). Requiring the
    /// word start is what keeps "senha" out of "resenha" (Portuguese for a review). Bare "key" and
    /// "token" are left out: a label such as "Keyboard shortcut" or "Token count" is not a secret.
    static let secretLabelWordStarts: [String] = [
        // pt, tr, pl, ru/uk
        "senha",
        "şifre", "parola",
        "hasło", "hasła", "haslo", "hasla",
        "парол",
        // Secrets that are not passwords
        "api key", "secret key", "secret access key", "access token", "private key",
        "recovery phrase", "seed phrase",
        "ssn", "social security"
    ]

    private static let labelMatchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// True when `label` names a password in one of the listed languages, or a secret such as an
    /// API key, recovery phrase or social security number. Shared with `CredentialFieldDetector`,
    /// which applies it to a single-line field's placeholder as well.
    static func labelNamesSecret(_ label: String) -> Bool {
        secretLabelSubstrings.contains { label.range(of: $0, options: labelMatchOptions) != nil }
            || secretLabelWordStarts.contains { startsWord($0, in: label) }
    }

    /// `term` occurs in `label` with no letter, mark or digit directly before it. Checked on Unicode
    /// scalars, so an index Foundation returns from a diacritic-insensitive match is never stepped
    /// back as a `Character`.
    static func startsWord(_ term: String, in label: String) -> Bool {
        var searchRange = label.startIndex..<label.endIndex
        while let found = label.range(of: term, options: labelMatchOptions, range: searchRange) {
            guard found.lowerBound > label.startIndex else { return true }
            let scalars = label.unicodeScalars
            let previous = scalars[scalars.index(before: found.lowerBound)]
            if !CharacterSet.alphanumerics.contains(previous) {
                return true
            }
            searchRange = found.upperBound..<label.endIndex
        }
        return false
    }
}
