import Foundation

/// Reads and writes Cotabby's app-specific `AppleLanguages` preference. Looking only in the named
/// persistent domain is important: `UserDefaults.string(forKey:)` searches the global domain too,
/// so it cannot distinguish a user's Mac-wide language choice from an explicit Cotabby override.
struct InterfaceLanguageSettingsStore {
    static let appleLanguagesKey = "AppleLanguages"

    private let userDefaults: UserDefaults
    private let bundleIdentifier: String

    init(
        userDefaults: UserDefaults = .standard,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.jacobfu.tabby"
    ) {
        self.userDefaults = userDefaults
        self.bundleIdentifier = bundleIdentifier
    }

    /// Returns the raw app-only preference without canonicalizing it or consulting macOS's global
    /// language list. Keeping raw startup data untouched protects future locales the current build
    /// does not offer.
    func appLanguageIdentifiers() -> [String]? {
        let value = userDefaults.persistentDomain(forName: bundleIdentifier)?[Self.appleLanguagesKey]
        if let identifiers = value as? [String] {
            return identifiers
        }
        if let identifier = value as? String {
            return [identifier]
        }
        return nil
    }

    /// Writes only Cotabby's persistent domain. `nil` means Follow System and removes the
    /// app-specific key, leaving the separate global `AppleLanguages` domain unchanged.
    func setAppLanguage(_ language: InterfaceLanguage?) {
        var domain = userDefaults.persistentDomain(forName: bundleIdentifier) ?? [:]
        if let language {
            domain[Self.appleLanguagesKey] = [language.rawValue]
        } else {
            domain.removeValue(forKey: Self.appleLanguagesKey)
        }

        if domain.isEmpty {
            userDefaults.removePersistentDomain(forName: bundleIdentifier)
        } else {
            userDefaults.setPersistentDomain(domain, forName: bundleIdentifier)
        }
    }
}
