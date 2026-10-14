import XCTest
@testable import Cotabby

/// The Rewrite Model rows: "Same as autocomplete" names the engine it follows, an unusable engine
/// row is marked and disabled, and the default and the API row can always be picked.
final class RewriteProviderRowPolicyTests: XCTestCase {
    func test_sameAsAutocompleteNamesTheAutocompleteEngine() {
        XCTAssertEqual(
            RewriteProviderRowPolicy.title(for: .sameAsAutocomplete, autocompleteEngineLabel: "MLX", isAvailable: true),
            "Same as autocomplete (MLX)")
        XCTAssertEqual(
            RewriteProviderRowPolicy.title(for: .sameAsAutocomplete, autocompleteEngineLabel: "Local Endpoint", isAvailable: false),
            "Same as autocomplete (Local Endpoint)",
            "the default row is never marked; its reason shows under the picker")
    }

    func test_sameAsAutocompleteSaysWhenItKeepsRewritesOnThisMac() {
        XCTAssertEqual(
            RewriteProviderRowPolicy.title(for: .sameAsAutocomplete, autocompleteEngineLabel: "Local Endpoint",
                                           sameAsAutocompleteStaysOnDevice: true, isAvailable: true),
            "Same as autocomplete (on this Mac: your endpoint is not local)")
    }

    func test_anUnavailableEngineRowIsMarkedAndDisabled() {
        let rows: [(RewriteProviderKind, String)] = [
            (.appleIntelligence, "Apple Intelligence"), (.openSource, "Open Source"),
            (.localEndpoint, "Local Endpoint"), (.mlx, "MLX")
        ]
        for (kind, label) in rows {
            XCTAssertEqual(RewriteProviderRowPolicy.title(for: kind, autocompleteEngineLabel: "Open Source", isAvailable: true), label)
            XCTAssertEqual(
                RewriteProviderRowPolicy.title(for: kind, autocompleteEngineLabel: "Open Source", isAvailable: false),
                "\(label) (Unavailable)")
            XCTAssertTrue(RewriteProviderRowPolicy.isSelectable(kind, isAvailable: true))
            XCTAssertFalse(RewriteProviderRowPolicy.isSelectable(kind, isAvailable: false), "\(kind)")
        }
    }

    func test_theDefaultAndTheAPIRowAreAlwaysSelectable() {
        for kind in [RewriteProviderKind.sameAsAutocomplete, .api] {
            XCTAssertTrue(RewriteProviderRowPolicy.isSelectable(kind, isAvailable: false), "\(kind)")
        }
        XCTAssertEqual(RewriteProviderRowPolicy.title(for: .api, autocompleteEngineLabel: "MLX", isAvailable: false), "API model")
    }
}
