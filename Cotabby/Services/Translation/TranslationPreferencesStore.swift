import Combine
import CoreGraphics
import Foundation

/// Owns the translation preferences and persists them in `UserDefaults`.
///
/// Kept out of `SuggestionSettingsModel` because translation is its own subsystem: nothing in the
/// suggestion pipeline reads these values, and the incoming/outgoing translation coordinators and
/// the Translation settings pane are their only readers. Built once by `CotabbyAppEnvironment`.
@MainActor
final class TranslationPreferencesStore: ObservableObject {
    @Published private(set) var preferences: TranslationPreferences

    private let userDefaults: UserDefaults

    private enum Key {
        static let isEnabled = "cotabbyTranslationEnabled"
        static let readingLanguage = "cotabbyTranslationReadingLanguage"
        static let apps = "cotabbyTranslationApps"
        static let translatesIncoming = "cotabbyTranslationIncoming"
        static let offersReply = "cotabbyTranslationReplies"
        static let replaceKeyCode = "cotabbyTranslationReplaceKeyCode"
        static let replaceKeyModifiers = "cotabbyTranslationReplaceKeyModifiers"
        static let replaceKeyLabel = "cotabbyTranslationReplaceKeyLabel"
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let defaults = TranslationPreferences.defaults
        preferences = TranslationPreferences(
            isEnabled: userDefaults.object(forKey: Key.isEnabled) as? Bool ?? defaults.isEnabled,
            readingLanguage: userDefaults.string(forKey: Key.readingLanguage) ?? defaults.readingLanguage,
            appBundleIdentifiers: userDefaults.stringArray(forKey: Key.apps) ?? defaults.appBundleIdentifiers,
            translatesIncoming: userDefaults.object(forKey: Key.translatesIncoming) as? Bool ?? defaults.translatesIncoming,
            offersReplyTranslation: userDefaults.object(forKey: Key.offersReply) as? Bool ?? defaults.offersReplyTranslation,
            replaceKeyCode: (userDefaults.object(forKey: Key.replaceKeyCode) as? Int).map { CGKeyCode($0) }
                ?? defaults.replaceKeyCode,
            replaceKeyModifiers: (userDefaults.object(forKey: Key.replaceKeyModifiers) as? Int).map { UInt32($0) }
                ?? defaults.replaceKeyModifiers,
            replaceKeyLabel: userDefaults.string(forKey: Key.replaceKeyLabel) ?? defaults.replaceKeyLabel
        )
    }

    /// Whether translation applies to windows of this app right now.
    func isActive(forBundleIdentifier bundleIdentifier: String?) -> Bool {
        guard preferences.isEnabled, let bundleIdentifier else { return false }
        return preferences.appBundleIdentifiers.contains(bundleIdentifier)
    }

    func setEnabled(_ enabled: Bool) {
        update(\.isEnabled, enabled, key: Key.isEnabled)
    }

    func setReadingLanguage(_ language: String) {
        update(\.readingLanguage, language, key: Key.readingLanguage)
    }

    func setTranslatesIncoming(_ enabled: Bool) {
        update(\.translatesIncoming, enabled, key: Key.translatesIncoming)
    }

    func setOffersReplyTranslation(_ enabled: Bool) {
        update(\.offersReplyTranslation, enabled, key: Key.offersReply)
    }

    func setApp(_ bundleIdentifier: String, included: Bool) {
        var apps = preferences.appBundleIdentifiers.filter { $0 != bundleIdentifier }
        if included { apps.append(bundleIdentifier) }
        update(\.appBundleIdentifiers, apps, key: Key.apps)
    }

    func setReplaceKey(keyCode: CGKeyCode, modifiers: UInt32, label: String) {
        guard preferences.replaceKeyCode != keyCode || preferences.replaceKeyModifiers != modifiers
            || preferences.replaceKeyLabel != label else { return }
        preferences.replaceKeyCode = keyCode
        preferences.replaceKeyModifiers = modifiers
        preferences.replaceKeyLabel = label
        userDefaults.set(Int(keyCode), forKey: Key.replaceKeyCode)
        userDefaults.set(Int(modifiers), forKey: Key.replaceKeyModifiers)
        userDefaults.set(label, forKey: Key.replaceKeyLabel)
    }

    private func update<Value: Equatable>(_ keyPath: WritableKeyPath<TranslationPreferences, Value>, _ value: Value, key: String) {
        guard preferences[keyPath: keyPath] != value else { return }
        preferences[keyPath: keyPath] = value
        userDefaults.set(value, forKey: key)
    }
}
