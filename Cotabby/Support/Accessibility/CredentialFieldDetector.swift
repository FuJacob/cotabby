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
/// the attributes (once per focus session) and asks here on every poll.
///
/// Every signal is matched by whole words or whole id parts, never by raw substring. Blocking
/// costs the writer their completions, so "phonebook-search", "emailSearch" and "Email subject"
/// must stay ordinary fields even though they contain a credential word.
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

    /// Words that make a label describe writing *about* email or phone rather than an identity
    /// input: "Email subject", "Email preview text", "Search email". Such a label is not a
    /// credential label even though it contains a keyword. Whole words, like the keywords.
    static let proseLabelWords: [String] = [
        "subject", "message", "body", "preview", "title", "signature", "template",
        "comment", "note", "notes", "reply", "search"
    ]

    /// Id parts that name a credential on their own. A few compounds whose pieces are only
    /// qualifiers ("identifierId" is Google's sign-in box, "onetimecode") are listed whole.
    static let credentialIdentifierWords: [String] = [
        "email", "mail", "username", "userid", "login", "logon", "signin", "passwd", "password", "pwd",
        "passcode", "otp", "totp", "mfa", "2fa", "phone", "telephone", "tel", "mobile", "msisdn", "pin",
        "cvc", "cvv", "cardnumber", "identifierid", "onetimecode", "verificationcode", "securitycode", "authcode"
    ]

    /// Id parts that commonly sit next to a credential word ("user_email", "txtPassword",
    /// "phoneNumber", "login_field") but name nothing on their own.
    static let qualifierIdentifierWords: [String] = [
        "user", "account", "address", "addr", "id", "identifier", "name", "number", "num", "no", "code",
        "field", "input", "txt", "tb", "verification", "verify", "security", "auth", "onetime", "confirm",
        "current", "new", "primary", "your", "enter"
    ]

    /// Ids longer than this are generated names (framework hashes, long paths), not a sign-in
    /// field's name, and are not worth segmenting on every poll.
    static let maximumIdentifierLength = 64

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

        if labels.contains(where: { $0.map(labelNamesCredential) ?? false }) {
            return true
        }

        if let domIdentifier, domIdentifierNamesCredential(domIdentifier) {
            return true
        }

        return looksLikeAddressEntry(text)
    }

    /// A label names a credential input when it contains a keyword as a whole word and no word
    /// that turns it into a description of prose ("Email" yes, "Email subject" no).
    static func labelNamesCredential(_ label: String) -> Bool {
        let label = label.lowercased()
        guard labelKeywords.contains(where: { containsWord($0, in: label) }) else { return false }
        return !proseLabelWords.contains(where: { containsWord($0, in: label) })
    }

    /// A DOM id names a credential input when the whole id splits into known id parts and at least
    /// one of them names a credential: "user_email", "loginEmail", "phonenumber" and "identifierId"
    /// do; "emailSearch" and "phonebook-search" do not, because "search" and "phonebook" are not
    /// sign-in vocabulary. Case, separators and digits are ignored, so "user_email", "userEmail"
    /// and "useremail2" read the same; that is also why lowercase run-together ids still match.
    static func domIdentifierNamesCredential(_ identifier: String) -> Bool {
        let characters = Array(identifier.lowercased().filter { $0.isLetter || $0.isNumber })
        guard !characters.isEmpty, characters.count <= maximumIdentifierLength else { return false }

        // Word-break over the vocabulary. `reach[i]` is nil when no split of the first `i`
        // characters exists, false when one exists, and true when one exists that includes a
        // credential word. Digits are skipped one at a time (numbered ids such as "email2").
        var reach = [Bool?](repeating: nil, count: characters.count + 1)
        reach[0] = false
        for start in characters.indices {
            guard let namesCredential = reach[start] else { continue }
            if characters[start].isNumber {
                reach[start + 1] = (reach[start + 1] ?? false) || namesCredential
            }
            for entry in identifierVocabulary where characters[start...].starts(with: entry.word) {
                let end = start + entry.word.count
                reach[end] = (reach[end] ?? false) || namesCredential || entry.namesCredential
            }
        }
        return reach[characters.count] == true
    }

    /// The whole value is one address-shaped token, finished or still being typed ("alice@",
    /// "alice@gmail.com"), as in a login box. Matching the unfinished address matters: a field with
    /// no telling label or id would otherwise get a guessed domain while the user types theirs. A
    /// slash or colon before the "@" marks a URL ("medium.com/@alice"), not an address.
    static func looksLikeAddressEntry(_ text: String?) -> Bool {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return false }
        return text.range(of: #"^[^\s@/:]+@[^\s@/:]*$"#, options: .regularExpression) != nil
    }

    private static let identifierVocabulary: [(word: [Character], namesCredential: Bool)] =
        credentialIdentifierWords.map { (Array($0), true) } + qualifierIdentifierWords.map { (Array($0), false) }

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
