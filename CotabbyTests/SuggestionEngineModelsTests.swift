import Foundation
import XCTest
@testable import Cotabby

/// Tests for the engine-choice domain models: the product-facing engine labels, the power-profile
/// bridge back to an engine kind, and the persisted app-blocklist entry.
final class SuggestionEngineModelsTests: XCTestCase {
    func test_suggestionEngineKind_displayLabelsArePinnedProductCopy() {
        XCTAssertEqual(SuggestionEngineKind.appleIntelligence.displayLabel, "Apple Intelligence")
        XCTAssertEqual(SuggestionEngineKind.llamaOpenSource.displayLabel, "Open Source")
    }

    func test_suggestionEngineKind_idMatchesRawValueForEveryCase() {
        XCTAssertEqual(SuggestionEngineKind.allCases.count, 2)
        for kind in SuggestionEngineKind.allCases {
            XCTAssertEqual(kind.id, kind.rawValue)
        }
    }

    func test_suggestionEngineKind_onlyOpenSourceManagesLocalModels() {
        // Apple Intelligence has no GGUF files to manage; the OS owns its model.
        XCTAssertFalse(SuggestionEngineKind.appleIntelligence.supportsLocalModelManagement)
        XCTAssertTrue(SuggestionEngineKind.llamaOpenSource.supportsLocalModelManagement)
    }

    func test_powerProfile_engineBridgesEachProfileToItsEngineKind() {
        XCTAssertEqual(PowerProfile.appleIntelligence.engine, .appleIntelligence)
        XCTAssertEqual(PowerProfile.llama(filename: "tabby.gguf").engine, .llamaOpenSource)
    }

    func test_disabledApplicationRule_identityIsBundleIdentifierAndSurvivesCodableRoundTrip() throws {
        let rule = DisabledApplicationRule(bundleIdentifier: "com.example.app", displayName: "Example")

        XCTAssertEqual(rule.id, "com.example.app")

        let decoded = try JSONDecoder().decode(
            DisabledApplicationRule.self,
            from: JSONEncoder().encode(rule)
        )
        XCTAssertEqual(decoded, rule)
    }
}
