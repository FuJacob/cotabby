import Combine
import CoreGraphics
import Foundation

/// Owns the Rewrite settings and persists them in `UserDefaults`.
///
/// Its own store rather than more keys on `SuggestionSettingsModel`, because nothing in autocomplete
/// reads these values: the rewrite coordinator, the engine and the Rewrite settings pane are the only readers.
/// API keys are not here; each cloud service's key lives in its own Keychain item
/// (`RewriteCredentialVault`). Built once by `CotabbyAppEnvironment`.
@MainActor
final class RewritePreferencesStore: ObservableObject {
    @Published private(set) var preferences: RewritePreferences

    private let userDefaults: UserDefaults

    private enum Key {
        static let isEnabled = "cotabbyRewriteEnabled"
        static let provider = "cotabbyRewriteProvider"
        static let apiBaseURL = "cotabbyRewriteAPIBaseURL"
        static let cloudProvider = "cotabbyRewriteCloudProvider"
        static let modelsByProvider = "cotabbyRewriteModelsByProvider"
        static let showsButton = "cotabbyRewriteShowsButton"
        static let fixesMistakes = "cotabbyRewriteFixesMistakes"
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let defaults = RewritePreferences.defaults
        var loaded = defaults
        loaded.isEnabled = userDefaults.object(forKey: Key.isEnabled) as? Bool ?? defaults.isEnabled
        loaded.provider = userDefaults.string(forKey: Key.provider).flatMap(RewriteProviderKind.init(rawValue:)) ?? defaults.provider
        loaded.apiBaseURL = userDefaults.string(forKey: Key.apiBaseURL) ?? defaults.apiBaseURL
        loaded.modelsByProvider = userDefaults.dictionary(forKey: Key.modelsByProvider) as? [String: String] ?? [:]
        loaded.cloudProvider = userDefaults.string(forKey: Key.cloudProvider)
            .flatMap(RewriteCloudProvider.init(rawValue:)) ?? defaults.cloudProvider
        loaded.showsButtonOnSelection = userDefaults.object(forKey: Key.showsButton) as? Bool ?? defaults.showsButtonOnSelection
        loaded.fixesMistakes = userDefaults.object(forKey: Key.fixesMistakes) as? Bool ?? defaults.fixesMistakes
        preferences = loaded
    }

    func setEnabled(_ value: Bool) {
        preferences.isEnabled = value
        userDefaults.set(value, forKey: Key.isEnabled)
    }

    func setProvider(_ provider: RewriteProviderKind) {
        preferences.provider = provider
        userDefaults.set(provider.rawValue, forKey: Key.provider)
    }

    func setAPIBaseURL(_ value: String) {
        preferences.apiBaseURL = value
        userDefaults.set(value, forKey: Key.apiBaseURL)
    }

    func setCloudProvider(_ provider: RewriteCloudProvider) {
        preferences.cloudProvider = provider
        userDefaults.set(provider.rawValue, forKey: Key.cloudProvider)
    }

    /// Sets the model for the current service only.
    func setAPIModelName(_ value: String) {
        preferences.apiModelName = value
        userDefaults.set(preferences.modelsByProvider, forKey: Key.modelsByProvider)
    }

    func setFixesMistakes(_ value: Bool) {
        preferences.fixesMistakes = value
        userDefaults.set(value, forKey: Key.fixesMistakes)
    }

    func setShowsButtonOnSelection(_ value: Bool) {
        preferences.showsButtonOnSelection = value
        userDefaults.set(value, forKey: Key.showsButton)
    }
}
