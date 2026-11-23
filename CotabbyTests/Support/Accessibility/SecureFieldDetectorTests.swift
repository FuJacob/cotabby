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

    // MARK: - Role half and label half

    /// The resolver judges the role pair on every poll, so this half alone must catch a field that
    /// turns into `AXSecureTextField` in place.
    func test_isSecureRole_judgesOnlyTheRolePair() {
        XCTAssertTrue(SecureFieldDetector.isSecureRole(role: "AXTextField", subrole: "AXSecureTextField"))
        XCTAssertFalse(SecureFieldDetector.isSecureRole(role: "AXTextField", subrole: nil))
        XCTAssertFalse(SecureFieldDetector.isSecureRole(role: "AXTextArea", subrole: ""))
    }

    func test_hasSecureLabel_coversRoleDescriptionAndLocalizedLabels() {
        XCTAssertTrue(SecureFieldDetector.hasSecureLabel(
            roleDescription: "secure text field", title: nil, descriptionLabel: nil))
        XCTAssertTrue(SecureFieldDetector.hasSecureLabel(
            roleDescription: "Textfeld", title: "Passwort", descriptionLabel: nil))
        XCTAssertTrue(SecureFieldDetector.hasSecureLabel(
            roleDescription: nil, title: nil, descriptionLabel: "Mot de passe"))
        XCTAssertFalse(SecureFieldDetector.hasSecureLabel(
            roleDescription: "text field", title: "Name", descriptionLabel: "Your full name"))
    }

    /// Italian says "password", which the original markers already match.
    func test_isSecure_italianPasswordLabel() {
        XCTAssertTrue(SecureFieldDetector.isSecure(
            role: "AXTextField", subrole: nil, roleDescription: "campo di testo",
            title: "Password", descriptionLabel: nil))
    }

    // MARK: - Secret label vocabulary

    func test_labelNamesSecret_localizedPasswordLabels() {
        let labels = [
            "Passwort", "Kennwort bestätigen", "Passwortbestätigung",
            "Mot de passe", "Contraseña", "Senha", "Digite sua senha",
            "Wachtwoord", "Lösenord", "Adgangskode", "Passord",
            "Hasło", "Potwierdź hasła", "Şifre", "Şifrenizi girin", "Parola",
            "Пароль", "Подтверждение пароля",
            "パスワードを入力", "密码", "密碼", "비밀번호를 입력하세요", "كلمة المرور", "הזן סיסמה"
        ]
        for label in labels {
            XCTAssertTrue(SecureFieldDetector.labelNamesSecret(label), label)
        }
    }

    func test_labelNamesSecret_ignoresCaseAndDiacritics() {
        for label in ["CONTRASENA", "contrasena", "LÖSENORD", "losenord", "PASSWORT", "ŞIFRE", "sifre"] {
            XCTAssertTrue(SecureFieldDetector.labelNamesSecret(label), label)
        }
    }

    func test_labelNamesSecret_secretsThatAreNotPasswords() {
        let labels = [
            "API key", "Your API keys", "Secret key", "AWS secret access key", "Access token",
            "Personal access token", "Private key", "Recovery phrase", "Secret Recovery Phrase",
            "Seed phrase", "SSN", "SSN (last 4 digits)", "Social security number"
        ]
        for label in labels {
            XCTAssertTrue(SecureFieldDetector.labelNamesSecret(label), label)
        }
    }

    /// Blocking costs the writer their completions, so bare "key" and "token", and words that only
    /// contain a term, stay ordinary.
    func test_labelNamesSecret_ordinaryLabelsStayOrdinary() {
        let labels = [
            "Key", "Token", "Token count", "Keyboard shortcut", "Primary key column", "Monkey business",
            "Escreva sua resenha", "Senhor", "CSS classnames", "Lessons learned", "Message", "Search",
            "Write a comment", "Subject"
        ]
        for label in labels {
            XCTAssertFalse(SecureFieldDetector.labelNamesSecret(label), label)
        }
    }

    func test_startsWord_requiresAWordStartButAllowsASuffix() {
        XCTAssertTrue(SecureFieldDetector.startsWord("senha", in: "Senhas"))
        XCTAssertTrue(SecureFieldDetector.startsWord("senha", in: "(senha)"))
        XCTAssertFalse(SecureFieldDetector.startsWord("senha", in: "resenha"))
        XCTAssertFalse(SecureFieldDetector.startsWord("ssn", in: "classnames"))
        XCTAssertFalse(SecureFieldDetector.startsWord("senha", in: ""))
    }
}
