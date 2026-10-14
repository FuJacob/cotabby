import XCTest
@testable import Cotabby

/// The engine resolves "Same as autocomplete" to the provider of the autocomplete engine, runs the
/// provider the user chose, and returns cleaned text or a clear error.
@MainActor
final class RewriteEngineTests: XCTestCase {
    private static var retained: [AnyObject] = []

    @MainActor
    private final class StubProvider: RewriteProviding {
        var isAvailable = true
        var unavailableReason: String?
        var hostName: String?
        var sendsOffDevice: Bool
        var output = "Please let me know if the dates work for you."
        private(set) var received: [RewriteRequest] = []
        init(offDevice: Bool) { sendsOffDevice = offDevice }
        func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
            received.append(request)
            onPartial(output)
            return output
        }
    }

    private let draft = "Please let me know if te dates are ok and wors for you."

    /// Every provider slot, as stubs: Apple Intelligence, Open Source and MLX stay on this Mac, the
    /// Local Endpoint stub is on loopback unless a test flips it, the API stub is off device.
    private struct Rig {
        let engine: RewriteEngine
        let apple: StubProvider
        let openSource: StubProvider
        let endpoint: StubProvider
        let mlx: StubProvider
        let api: StubProvider
    }

    private func makeRig(
        _ prefs: RewritePreferences = .defaults,
        autocomplete: SuggestionEngineKind = .llamaOpenSource,
        endpointScope: OpenAICompatibleHostScope? = .loopback
    ) -> Rig {
        let apple = StubProvider(offDevice: false)
        let openSource = StubProvider(offDevice: false)
        let endpoint = StubProvider(offDevice: false)
        let mlx = StubProvider(offDevice: false)
        let api = StubProvider(offDevice: true)
        let engine = RewriteEngine(
            appleIntelligence: apple, openSource: openSource, localEndpoint: endpoint, mlx: mlx, api: api,
            autocompleteEngine: { autocomplete }, endpointHostScope: { endpointScope }, preferences: { prefs })
        Self.retained.append(contentsOf: [engine, apple, openSource, endpoint, mlx, api] as [AnyObject])
        return Rig(engine: engine, apple: apple, openSource: openSource, endpoint: endpoint, mlx: mlx, api: api)
    }

    private func prefs(_ provider: RewriteProviderKind) -> RewritePreferences {
        var prefs = RewritePreferences.defaults
        prefs.provider = provider
        return prefs
    }

    func test_sameAsAutocompleteRunsOnTheProviderOfTheAutocompleteEngine() async throws {
        let request = RewriteRequest(selection: draft, action: .fixOnly)
        for (engineKind, pick) in [
            (SuggestionEngineKind.appleIntelligence, \Rig.apple), (.llamaOpenSource, \Rig.openSource),
            (.openAICompatible, \Rig.endpoint), (.mlx, \Rig.mlx)
        ] {
            let rig = makeRig(autocomplete: engineKind)
            _ = try await rig.engine.rewrite(request, onPartial: { _ in })
            XCTAssertEqual(rig[keyPath: pick].received.count, 1, "\(engineKind)")
            XCTAssertTrue(rig.api.received.isEmpty)
        }
    }

    func test_anExplicitChoiceBeatsTheAutocompleteEngine() async throws {
        let rig = makeRig(prefs(.appleIntelligence), autocomplete: .mlx)
        _ = try await rig.engine.rewrite(RewriteRequest(selection: draft, action: .fixOnly), onPartial: { _ in })
        XCTAssertEqual(rig.apple.received.count, 1)
        XCTAssertTrue(rig.mlx.received.isEmpty)
    }

    func test_eachExplicitKindRunsItsOwnProvider() async throws {
        for (kind, pick) in [
            (RewriteProviderKind.appleIntelligence, \Rig.apple), (.openSource, \Rig.openSource),
            (.localEndpoint, \Rig.endpoint), (.mlx, \Rig.mlx), (.api, \Rig.api)
        ] {
            let rig = makeRig(prefs(kind))
            _ = try await rig.engine.rewrite(RewriteRequest(selection: draft, action: .fixOnly), onPartial: { _ in })
            XCTAssertEqual(rig[keyPath: pick].received.count, 1, "\(kind)")
            XCTAssertTrue(rig.engine.activeProvider === rig[keyPath: pick], "\(kind)")
        }
    }

    func test_sameAsAutocompleteOnALoopbackEndpointUsesIt() {
        let rig = makeRig(autocomplete: .openAICompatible, endpointScope: .loopback)
        XCTAssertEqual(rig.engine.resolvedKind, .localEndpoint)
        XCTAssertTrue(rig.engine.activeProvider === rig.endpoint)
        XCTAssertEqual(rig.engine.destination(), RewriteDestination(kind: .localEndpoint, sendsOffDevice: false, hostName: nil))
        XCTAssertNil(rig.engine.destination().disclosure)
        XCTAssertFalse(rig.engine.sameAsAutocompleteStaysOnDevice)
    }

    /// The default never sends a rewrite to a LAN or public endpoint on its own.
    func test_sameAsAutocompleteOnARemoteEndpointRunsOnThisMac() async throws {
        let rig = makeRig(autocomplete: .openAICompatible, endpointScope: .localNetwork)
        rig.endpoint.sendsOffDevice = true
        XCTAssertTrue(rig.engine.sameAsAutocompleteStaysOnDevice)
        XCTAssertEqual(rig.engine.resolvedKind, .appleIntelligence)
        XCTAssertNil(rig.engine.destination().disclosure)
        _ = try await rig.engine.rewrite(RewriteRequest(selection: draft, action: .fixOnly), onPartial: { _ in })
        XCTAssertEqual(rig.apple.received.count, 1)
        XCTAssertTrue(rig.endpoint.received.isEmpty, "nothing reached the remote endpoint")

        let noAppleIntelligence = makeRig(autocomplete: .openAICompatible, endpointScope: .publicInternet)
        noAppleIntelligence.apple.isAvailable = false
        XCTAssertEqual(noAppleIntelligence.engine.resolvedKind, .openSource)
    }

    func test_explicitLocalEndpointOnARemoteHostIsUsedAndDisclosed() {
        let rig = makeRig(prefs(.localEndpoint), autocomplete: .openAICompatible, endpointScope: .publicInternet)
        rig.endpoint.sendsOffDevice = true
        rig.endpoint.hostName = "api.example.com"
        XCTAssertTrue(rig.engine.activeProvider === rig.endpoint)
        XCTAssertEqual(rig.engine.destination().kind, .localEndpoint)
        XCTAssertNotNil(rig.engine.destination().disclosure)
    }

    /// A popup's destination is fixed when it opens; if the provider would now send elsewhere (the
    /// endpoint's URL was edited meanwhile), the run sends nothing.
    func test_aDestinationThatNoLongerMatchesSendsNothing() async {
        let rig = makeRig(prefs(.localEndpoint), autocomplete: .openAICompatible)
        let disclosed = rig.engine.destination()
        rig.endpoint.sendsOffDevice = true
        do {
            _ = try await rig.engine.rewrite(RewriteRequest(selection: draft, action: .fixOnly), to: disclosed, onPartial: { _ in })
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RewriteError, .destinationChanged)
        }
        XCTAssertTrue(rig.endpoint.received.isEmpty)
    }

    func test_destinationDisclosureWording() {
        XCTAssertEqual(RewriteDestination(kind: .api, sendsOffDevice: true, hostName: "api.example.com").disclosure,
                       "The selected text is sent to api.example.com.")
        XCTAssertEqual(RewriteDestination(kind: .localEndpoint, sendsOffDevice: true, hostName: "10.0.0.5").disclosure,
                       "The selected text is sent to 10.0.0.5, the endpoint set up in Engine & Model.")
        XCTAssertNil(RewriteDestination(kind: .openSource, sendsOffDevice: false, hostName: nil).disclosure)
    }

    func test_providerForSameAsAutocompleteIsTheResolvedOne() {
        let rig = makeRig(autocomplete: .mlx)
        XCTAssertTrue(rig.engine.provider(for: .sameAsAutocomplete) === rig.mlx)
        XCTAssertTrue(rig.engine.provider(for: .openSource) === rig.openSource)
    }

    /// The request reaches the provider whole: language, tick box and the tone a refinement keeps.
    func test_requestReachesTheProviderUnchanged() async throws {
        let rig = makeRig(prefs(.api))
        var request = RewriteRequest(selection: draft, action: .shorter)
        request.language = "Turkish"
        request.fixesMistakes = false
        request.tone = .family
        _ = try await rig.engine.rewrite(request, onPartial: { _ in })
        XCTAssertEqual(rig.api.received.first, request)
    }

    func test_unavailableProviderThrowsItsOwnReason() async {
        let rig = makeRig(prefs(.mlx))
        rig.mlx.isAvailable = false
        rig.mlx.unavailableReason = "Install MLX in Settings → Engine & Model."
        do {
            _ = try await rig.engine.rewrite(RewriteRequest(selection: draft, action: .rewrite), onPartial: { _ in })
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RewriteError, .unavailable("Install MLX in Settings → Engine & Model."))
        }
    }

    func test_unavailableProviderWithoutAReasonThrowsNoProvider() async {
        let rig = makeRig()
        rig.openSource.isAvailable = false
        do {
            _ = try await rig.engine.rewrite(RewriteRequest(selection: draft, action: .rewrite), onPartial: { _ in })
            XCTFail("Expected noProvider")
        } catch {
            XCTAssertEqual(error as? RewriteError, .noProvider)
        }
    }

    func test_unusableOutputThrows() async {
        let rig = makeRig()
        rig.openSource.output = "   "
        do {
            _ = try await rig.engine.rewrite(RewriteRequest(selection: draft, action: .rewrite), onPartial: { _ in })
            XCTFail("Expected unusableOutput")
        } catch {
            XCTAssertEqual(error as? RewriteError, .unusableOutput)
        }
    }

    func test_tooLongSelectionThrows() async {
        let rig = makeRig()
        let long = String(repeating: "word ", count: 401)
        do {
            _ = try await rig.engine.rewrite(RewriteRequest(selection: long, action: .rewrite), onPartial: { _ in })
            XCTFail("Expected selectionTooLong")
        } catch {
            XCTAssertEqual(error as? RewriteError, .selectionTooLong)
        }
    }
}

/// Collects what the relay delivered, on the main actor where the relay delivers.
@MainActor
private final class DeliveryLog {
    private(set) var items: [String] = []
    func append(_ text: String) { items.append(text) }

}

/// The relay keeps streamed partials ordered (latest wins) and delivers nothing after `finish()`.
@MainActor
final class PartialRelayTests: XCTestCase {
    func test_relayDropsOlderPartials() async {
        let log = DeliveryLog()
        let relay = PartialRelay(deliver: { log.append($0) })
        // Send from a background thread, like the llama runtime's callback.
        await Task.detached { relay.send("a"); relay.send("ab"); relay.send("abc") }.value
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(log.items.last, "abc")
        let lengths = log.items.map(\.count)
        XCTAssertEqual(lengths, lengths.sorted(), "an older partial was delivered after a newer one")
        XCTAssertEqual(Set(lengths).count, lengths.count, "a partial was delivered twice")
    }

    func test_relayDeliversNothingAfterFinish() async {
        let log = DeliveryLog()
        let relay = PartialRelay(deliver: { log.append($0) })
        relay.send("x")
        relay.finish()
        relay.send("late")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(log.items.contains("late"), "a partial was delivered after finish()")
        XCTAssertTrue(log.items.isEmpty, "a partial sent before finish() was delivered after it")
    }

}
