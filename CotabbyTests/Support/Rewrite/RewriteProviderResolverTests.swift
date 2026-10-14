import XCTest
@testable import Cotabby

/// "Same as autocomplete" is resolved by one pure function: it follows the autocomplete engine but
/// never sends a rewrite off this Mac on its own. Every other choice passes through.
final class RewriteProviderResolverTests: XCTestCase {
    private func resolve(
        _ kind: RewriteProviderKind,
        _ engine: SuggestionEngineKind,
        scope: OpenAICompatibleHostScope? = .loopback,
        appleIntelligence: Bool = true
    ) -> RewriteProviderKind {
        RewriteProviderResolver.resolve(kind, autocompleteEngine: engine, endpointHostScope: scope,
                                        appleIntelligenceAvailable: appleIntelligence)
    }

    func test_sameAsAutocompleteFollowsTheAutocompleteEngine() {
        let expected: [(SuggestionEngineKind, RewriteProviderKind)] = [
            (.appleIntelligence, .appleIntelligence),
            (.llamaOpenSource, .openSource),
            (.openAICompatible, .localEndpoint),
            (.mlx, .mlx)
        ]
        for (engine, kind) in expected {
            XCTAssertEqual(resolve(.sameAsAutocomplete, engine), kind, "\(engine)")
        }
    }

    func test_sameAsAutocompleteStaysOnThisMacWhenTheEndpointIsNotLocal() {
        for scope in [OpenAICompatibleHostScope.localNetwork, .publicInternet] {
            XCTAssertEqual(resolve(.sameAsAutocomplete, .openAICompatible, scope: scope, appleIntelligence: true),
                           .appleIntelligence, "\(scope)")
            XCTAssertEqual(resolve(.sameAsAutocomplete, .openAICompatible, scope: scope, appleIntelligence: false),
                           .openSource, "\(scope)")
            XCTAssertTrue(RewriteProviderResolver.sameAsAutocompleteStaysOnDevice(
                autocompleteEngine: .openAICompatible, endpointHostScope: scope))
        }
    }

    func test_aLoopbackOrUnconfiguredEndpointKeepsTheEndpoint() {
        XCTAssertEqual(resolve(.sameAsAutocomplete, .openAICompatible, scope: .loopback), .localEndpoint)
        // Unconfigured: the Local Endpoint provider sends nothing and reports why.
        XCTAssertEqual(resolve(.sameAsAutocomplete, .openAICompatible, scope: nil), .localEndpoint)
        XCTAssertFalse(RewriteProviderResolver.sameAsAutocompleteStaysOnDevice(
            autocompleteEngine: .openAICompatible, endpointHostScope: .loopback))
        XCTAssertFalse(RewriteProviderResolver.sameAsAutocompleteStaysOnDevice(
            autocompleteEngine: .mlx, endpointHostScope: .publicInternet), "only an endpoint engine falls back")
    }

    func test_explicitLocalEndpointStillSendsToAnyHost() {
        for scope in [OpenAICompatibleHostScope.loopback, .localNetwork, .publicInternet] {
            XCTAssertEqual(resolve(.localEndpoint, .openAICompatible, scope: scope), .localEndpoint)
        }
    }

    func test_explicitChoicesIgnoreTheAutocompleteEngine() {
        let explicit: [RewriteProviderKind] = [.appleIntelligence, .openSource, .localEndpoint, .mlx, .api]
        for kind in explicit {
            for engine in SuggestionEngineKind.allCases {
                XCTAssertEqual(resolve(kind, engine, scope: .publicInternet, appleIntelligence: false), kind)
            }
        }
    }

    func test_usesMLXOnlyForMLXOrSameAsAutocompleteOnMLX() {
        XCTAssertTrue(RewriteProviderResolver.usesMLX(.mlx, autocompleteEngine: .appleIntelligence))
        XCTAssertTrue(RewriteProviderResolver.usesMLX(.sameAsAutocomplete, autocompleteEngine: .mlx))
        XCTAssertFalse(RewriteProviderResolver.usesMLX(.sameAsAutocomplete, autocompleteEngine: .openAICompatible))
        XCTAssertFalse(RewriteProviderResolver.usesMLX(.api, autocompleteEngine: .mlx))
    }

    func test_persistedRawValues() {
        XCTAssertEqual(RewriteProviderKind(rawValue: "api"), .api)
        XCTAssertEqual(RewriteProviderKind(rawValue: "mlx"), .mlx)
        XCTAssertEqual(RewriteProviderKind(rawValue: "sameAsAutocomplete"), .sameAsAutocomplete)
        XCTAssertNil(RewriteProviderKind(rawValue: "local"), "local is migrated by the store, not decoded")
    }
}
