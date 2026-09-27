import Foundation
import XCTest
@testable import Cotabby

/// Tests for the engine-choice domain models: the product-facing engine labels and persisted raw
/// values, the power-profile bridge back to an engine kind, the persisted app-blocklist entry shape,
/// and the snapshot's single word-range chokepoint.
final class SuggestionEngineModelsTests: XCTestCase {
    func test_suggestionEngineKind_displayLabelsArePinnedProductCopy() {
        XCTAssertEqual(SuggestionEngineKind.appleIntelligence.displayLabel, "Apple Intelligence")
        XCTAssertEqual(SuggestionEngineKind.llamaOpenSource.displayLabel, "Open Source")
        XCTAssertEqual(SuggestionEngineKind.openAICompatible.displayLabel, "Local Endpoint")
    }

    func test_suggestionEngineKind_systemImageNamesArePinnedSharedGlyphs() {
        // Onboarding's engine cards and Settings' Home status card render these; pinning them keeps
        // the engine looking like one object across every surface.
        XCTAssertEqual(SuggestionEngineKind.appleIntelligence.systemImageName, "apple.logo")
        XCTAssertEqual(SuggestionEngineKind.llamaOpenSource.systemImageName, "cpu.fill")
        XCTAssertEqual(SuggestionEngineKind.openAICompatible.systemImageName, "network")
    }

    func test_suggestionEngineKind_rawValuesArePersistedIdentifiers() {
        // Stored under `cotabbySelectedEngine` and the battery/plugged-in engine keys; a rename
        // would silently reset every saved engine choice.
        XCTAssertEqual(
            SuggestionEngineKind.allCases.map(\.rawValue),
            ["appleIntelligence", "llamaOpenSource", "openAICompatible"]
        )
    }

    func test_suggestionEngineKind_onlyOpenSourceManagesLocalModels() {
        // Apple Intelligence has no GGUF files to manage; the OS owns its model.
        XCTAssertFalse(SuggestionEngineKind.appleIntelligence.supportsLocalModelManagement)
        XCTAssertTrue(SuggestionEngineKind.llamaOpenSource.supportsLocalModelManagement)
        XCTAssertFalse(SuggestionEngineKind.openAICompatible.supportsLocalModelManagement)
    }

    func test_powerProfile_engineBridgesEachProfileToItsEngineKind() {
        XCTAssertEqual(PowerProfile.appleIntelligence.engine, .appleIntelligence)
        XCTAssertEqual(PowerProfile.llama(filename: "tabby.gguf").engine, .llamaOpenSource)
        XCTAssertEqual(PowerProfile.openAICompatible(modelName: "gemma4").engine, .openAICompatible)
    }

    func test_acceptanceGranularity_rawValuesArePersistedIdentifiers() {
        XCTAssertEqual(AcceptanceGranularity.allCases.map(\.rawValue), ["word", "phrase"])
    }

    func test_disabledApplicationRule_decodesThePersistedKeyShapeAndUsesBundleAsIdentity() throws {
        // `cotabbyDisabledAppRules` stores a JSON array of these rows. Decoding a literal pins the
        // key names, so renaming a property cannot silently drop every user's blocklist.
        let json = Data(#"[{"bundleIdentifier":"com.example.app","displayName":"Example"}]"#.utf8)

        let rules = try JSONDecoder().decode([DisabledApplicationRule].self, from: json)

        XCTAssertEqual(rules, [DisabledApplicationRule(bundleIdentifier: "com.example.app", displayName: "Example")])
        XCTAssertEqual(rules.first?.id, "com.example.app")
    }

    // MARK: - SuggestionSettingsSnapshot

    func test_effectiveWordRange_usesPresetUnlessCustomRangeIsActive() {
        let custom = SuggestionWordRange(lowWords: 3, highWords: 9)

        let presetSnapshot = CotabbyTestFixtures.settingsSnapshot(
            selectedWordCountPreset: .fourToSeven,
            isUsingCustomWordCountRange: false,
            customWordCountRange: custom
        )
        XCTAssertEqual(presetSnapshot.effectiveWordRange, SuggestionWordCountPreset.fourToSeven.range)

        let customSnapshot = CotabbyTestFixtures.settingsSnapshot(
            selectedWordCountPreset: .fourToSeven,
            isUsingCustomWordCountRange: true,
            customWordCountRange: custom
        )
        XCTAssertEqual(customSnapshot.effectiveWordRange, custom)
    }
}
