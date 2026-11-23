import Foundation

/// Apps whose fields typing history never records, whatever the user's own exclusion list holds.
///
/// A password manager's password fields are secure and already skipped, but its other fields are
/// ordinary text fields: secure notes, recovery codes, card details, the username and URL of every
/// login. Recording them would copy the vault into history. Waiting for each user to exclude their
/// password manager by hand leaves that copy in place for everyone who never opens the setting.
///
/// The list is a fixed, built-in rule like the terminal check in `TypingHistoryStore`, not entries
/// seeded into the user's list: it reaches existing users without a migration and leaves the list
/// they edited untouched. Only bundle identifiers checked against the vendor's own build files, its
/// Homebrew cask, or an installed copy are listed; a guessed identifier would only look like
/// protection.
nonisolated enum TypingHistoryDefaultExclusions {
    static let passwordManagerBundleIdentifiers: Set<String> = [
        "com.1password.1password",       // 1Password 8
        "com.bitwarden.desktop",         // Bitwarden
        "org.keepassxc.keepassxc",       // KeePassXC
        "com.hicknhacksoftware.MacPass", // MacPass
        "com.nordsec.nordpass",          // NordPass
        "me.proton.pass.electron",       // Proton Pass
        "com.apple.Passwords",           // Passwords (macOS 15 and later)
        "com.apple.keychainaccess"       // Keychain Access
    ]

    static func isExcluded(bundleIdentifier: String) -> Bool {
        passwordManagerBundleIdentifiers.contains(bundleIdentifier)
    }
}
