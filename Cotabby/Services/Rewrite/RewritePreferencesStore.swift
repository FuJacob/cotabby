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

    /// `appleIntelligence` is the availability the app knows at launch (nil: not known yet). It only
    /// matters for a stored `local` (the earlier "Apple Intelligence, else Cotabby's model" choice),
    /// which becomes whichever of the two it was running, but only on a definitive answer:
    /// `.available` → Apple Intelligence, a permanent unavailable state → Open Source. A transient
    /// state (the model still downloading right after login) leaves `local` stored and runs Open
    /// Source in memory for now; `noteAppleIntelligence(_:)` migrates once the answer is definitive.
    init(
        userDefaults: UserDefaults = .standard,
        isAppleSilicon: Bool = MLXHardware.isAppleSilicon,
        appleIntelligence: FoundationModelAvailabilityState?
    ) {
        self.userDefaults = userDefaults
        let defaults = RewritePreferences.defaults
        var loaded = defaults
        loaded.isEnabled = userDefaults.object(forKey: Key.isEnabled) as? Bool ?? defaults.isEnabled
        let stored = userDefaults.string(forKey: Key.provider)
        if stored == Self.legacyLocal {
            if let migrated = Self.definitiveMigration(appleIntelligence) {
                loaded.provider = migrated
                userDefaults.set(migrated.rawValue, forKey: Key.provider)
            } else {
                loaded.provider = .openSource
            }
        } else {
            loaded.provider = stored.flatMap(RewriteProviderKind.init(rawValue:)) ?? defaults.provider
        }
        // MLX needs Apple Silicon; a stored choice (e.g. settings copied from another Mac) falls
        // back to the local llama path so the picker always has a usable entry.
        if loaded.provider == .mlx, !isAppleSilicon { loaded.provider = .openSource }
        loaded.apiBaseURL = userDefaults.string(forKey: Key.apiBaseURL) ?? defaults.apiBaseURL
        loaded.modelsByProvider = userDefaults.dictionary(forKey: Key.modelsByProvider) as? [String: String] ?? [:]
        loaded.cloudProvider = userDefaults.string(forKey: Key.cloudProvider)
            .flatMap(RewriteCloudProvider.init(rawValue:)) ?? defaults.cloudProvider
        loaded.showsButtonOnSelection = userDefaults.object(forKey: Key.showsButton) as? Bool ?? defaults.showsButtonOnSelection
        loaded.fixesMistakes = userDefaults.object(forKey: Key.fixesMistakes) as? Bool ?? defaults.fixesMistakes
        preferences = loaded
    }

    private static let legacyLocal = "local"

    /// The provider a stored `local` becomes for this availability, or nil while the answer is not
    /// definitive.
    private static func definitiveMigration(_ state: FoundationModelAvailabilityState?) -> RewriteProviderKind? {
        guard let state else { return nil }
        if state.isAvailable { return .appleIntelligence }
        return state.isPermanentlyUnavailable ? .openSource : nil
    }

    /// Called for every availability change: finishes a migration that launch could not decide.
    /// Does nothing once the user (or an earlier answer) replaced the stored `local`.
    func noteAppleIntelligence(_ state: FoundationModelAvailabilityState) {
        guard userDefaults.string(forKey: Key.provider) == Self.legacyLocal,
              let migrated = Self.definitiveMigration(state) else { return }
        setProvider(migrated)
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
