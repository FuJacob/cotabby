import Foundation
import Testing
@testable import Cotabby

/// Pins the separate interface-language preference boundary: app-domain persistence, startup
/// preservation, locale normalization, and restart state all remain independent of suggestion rules.
@MainActor
struct InterfaceLanguageSettingsModelTests {
    @Test
    func selectionWritesOnlyTheAppDomainAndLeavesGlobalLanguageAlone() throws {
        let (defaults, domain, store) = try makeStore()
        let originalGlobalDomain = defaults.volatileDomain(forName: UserDefaults.globalDomain)
        defaults.setVolatileDomain(
            originalGlobalDomain.merging(["AppleLanguages": ["fr-CA"]]) { _, new in new },
            forName: UserDefaults.globalDomain
        )
        defer {
            clean(defaults, domain: domain)
            defaults.setVolatileDomain(originalGlobalDomain, forName: UserDefaults.globalDomain)
        }

        let model = InterfaceLanguageSettingsModel(store: store)
        #expect(model.selection == .followSystem)
        model.select(.language(.japanese))

        #expect(defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String] == ["ja"])
        #expect(
            defaults.volatileDomain(forName: UserDefaults.globalDomain)["AppleLanguages"] as? [String] == ["fr-CA"]
        )
        #expect(model.restartRequired)
    }

    @Test
    func unsupportedStartupOverrideIsPreservedUntilTheUserChoosesFollowSystem() throws {
        let (defaults, domain, store) = try makeStore()
        defer { clean(defaults, domain: domain) }
        defaults.setPersistentDomain(
            ["AppleLanguages": ["xx-ZZ"], "unrelatedPreference": "keep"],
            forName: domain
        )

        let model = InterfaceLanguageSettingsModel(store: store)
        #expect(model.selection == .preservedUnsupported("xx-ZZ"))
        #expect(!model.restartRequired)
        #expect(store.appLanguageIdentifiers() == ["xx-ZZ"])

        // The conditional Picker item gives this unsupported value a distinct tag, so choosing
        // Follow System is a real selection change and explicitly removes the app-only override.
        model.select(.followSystem)

        let updatedDomain = defaults.persistentDomain(forName: domain) ?? [:]
        #expect(updatedDomain["AppleLanguages"] == nil)
        #expect(updatedDomain["unrelatedPreference"] as? String == "keep")
        #expect(model.restartRequired)
    }

    @Test
    func restartNoticeClearsWhenSelectionReturnsToTheLaunchLanguage() throws {
        let (defaults, domain, store) = try makeStore()
        defer { clean(defaults, domain: domain) }
        defaults.setPersistentDomain(["AppleLanguages": ["en-US"]], forName: domain)

        let model = InterfaceLanguageSettingsModel(store: store)
        #expect(model.selection == .language(.english))
        #expect(!model.restartRequired)

        model.select(.language(.french))
        #expect(model.restartRequired)

        model.select(.language(.english))
        #expect(!model.restartRequired)
        #expect(store.appLanguageIdentifiers() == ["en"])
    }

    @Test
    func resetToFollowSystemAlsoClearsAnUnsupportedOverride() throws {
        let (defaults, domain, store) = try makeStore()
        defer { clean(defaults, domain: domain) }
        defaults.setPersistentDomain(["AppleLanguages": ["xx-ZZ"]], forName: domain)

        let model = InterfaceLanguageSettingsModel(store: store)
        model.resetToFollowSystem()

        #expect(model.selection == .followSystem)
        #expect(model.restartRequired)
        #expect((defaults.persistentDomain(forName: domain) ?? [:])["AppleLanguages"] == nil)
    }

    private func makeStore() throws -> (UserDefaults, String, InterfaceLanguageSettingsStore) {
        let domain = "InterfaceLanguageSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        return (defaults, domain, InterfaceLanguageSettingsStore(userDefaults: defaults, bundleIdentifier: domain))
    }

    private func clean(_ defaults: UserDefaults, domain: String) {
        defaults.removePersistentDomain(forName: domain)
    }
}
