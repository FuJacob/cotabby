import Combine
import Foundation

/// Owns the per-window feature choices made from the field icon and persists them in
/// `UserDefaults`.
///
/// Why its own store: app-level choices already live with their features (the disabled-apps list in
/// `SuggestionSettingsModel`, the app list in `TranslationPreferencesStore`), and both are read far
/// more widely than window choices. Window choices are a thin override layer that only the field
/// icon writes, so they stay in one small store instead of widening either settings model. Built
/// once by `CotabbyAppEnvironment`; the suggestion coordinator, translation coordinator, indicator,
/// and popup read it through `override(for:windowKey:)`.
@MainActor
final class WindowFeatureOverrideStore: ObservableObject {
    /// Window key (from `WindowFeatureScope.windowKey`) to on/off, per feature. A missing entry
    /// means the window follows its app.
    @Published private(set) var overrides: [ScopedFeature: [String: Bool]]

    /// Oldest entries are dropped beyond this many windows per feature, so a long-lived install that
    /// visits thousands of chats keeps a bounded defaults payload.
    static let maximumWindowsPerFeature = 500

    private let userDefaults: UserDefaults
    private static let defaultsKeyPrefix = "cotabbyWindowFeatureOverrides."
    /// Insertion order per feature, newest last, persisted beside the map so trimming is stable.
    private var order: [ScopedFeature: [String]]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        var overrides: [ScopedFeature: [String: Bool]] = [:]
        var order: [ScopedFeature: [String]] = [:]
        for feature in ScopedFeature.allCases {
            let stored = userDefaults.array(forKey: Self.defaultsKeyPrefix + feature.rawValue) as? [[String: Any]] ?? []
            var map: [String: Bool] = [:]
            var keys: [String] = []
            for entry in stored {
                guard let key = entry["window"] as? String, let enabled = entry["enabled"] as? Bool else { continue }
                if map.updateValue(enabled, forKey: key) == nil { keys.append(key) }
            }
            overrides[feature] = map
            order[feature] = keys
        }
        self.overrides = overrides
        self.order = order
    }

    /// The window's own choice for a feature, or nil when it follows the app.
    func override(for feature: ScopedFeature, windowKey: String?) -> Bool? {
        guard let windowKey else { return nil }
        return overrides[feature]?[windowKey]
    }

    /// Whether any window of this app has the feature forced on. Translation uses it to decide
    /// whether a capture is worth taking before it knows which window is in front.
    func hasEnabledWindow(for feature: ScopedFeature, bundleIdentifier: String) -> Bool {
        let prefix = bundleIdentifier + "\u{1F}"
        return overrides[feature]?.contains { $0.key.hasPrefix(prefix) && $0.value } ?? false
    }

    /// Sets (or with nil, clears) a window's choice for a feature.
    func setOverride(_ enabled: Bool?, for feature: ScopedFeature, windowKey: String) {
        var map = overrides[feature] ?? [:]
        var keys = (order[feature] ?? []).filter { $0 != windowKey }
        if let enabled {
            map[windowKey] = enabled
            keys.append(windowKey)
        } else {
            map.removeValue(forKey: windowKey)
        }
        while keys.count > Self.maximumWindowsPerFeature {
            map.removeValue(forKey: keys.removeFirst())
        }
        guard map != overrides[feature] else { return }
        overrides[feature] = map
        order[feature] = keys
        userDefaults.set(
            keys.compactMap { key in map[key].map { ["window": key, "enabled": $0] as [String: Any] } },
            forKey: Self.defaultsKeyPrefix + feature.rawValue
        )
    }
}
