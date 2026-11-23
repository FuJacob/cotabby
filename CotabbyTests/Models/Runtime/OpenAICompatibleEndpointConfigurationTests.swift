import Foundation
import XCTest
@testable import Cotabby

/// Tests for the endpoint value boundary: host privacy classification (which decides whether plain
/// HTTP is allowed and which disclosure the Settings pane shows), base-URL normalization, and the
/// small route/state/error vocabulary the endpoint pane renders. Transport behavior lives in
/// `OpenAICompatibleAPIClientTests`.
final class OpenAICompatibleEndpointConfigurationTests: XCTestCase {
    // MARK: - Host scope

    func test_hostScope_classifiesLoopbackPrivateAndPublicHosts() {
        let expectations: [(host: String, scope: OpenAICompatibleHostScope)] = [
            ("localhost", .loopback),
            ("LOCALHOST", .loopback),
            ("api.localhost", .loopback),
            ("::1", .loopback),
            ("[::1]", .loopback),
            ("127.0.0.1", .loopback),
            ("127.8.9.10", .loopback),
            ("10.0.0.5", .localNetwork),
            ("172.16.0.1", .localNetwork),
            ("172.31.255.255", .localNetwork),
            ("192.168.1.50", .localNetwork),
            ("169.254.10.10", .localNetwork),
            ("ollama.local", .localNetwork),
            ("fd12:3456::1", .localNetwork),
            ("fe80::1", .localNetwork),
            // Just outside the RFC 1918 172.16/12 block.
            ("172.15.0.1", .publicInternet),
            ("172.32.0.1", .publicInternet),
            ("8.8.8.8", .publicInternet),
            // Not a valid IPv4 literal, so it is treated as a DNS name.
            ("256.1.1.1", .publicInternet),
            ("models.example.com", .publicInternet),
            // A single-label name may resolve publicly, so it is not assumed to be on the LAN.
            ("internal-llm", .publicInternet),
            // The IPv6 unique-local and link-local rules apply to parsed addresses only. DNS names
            // that merely start with the same letters are ordinary public hosts.
            ("fdic.gov", .publicInternet),
            ("fd.example.com", .publicInternet),
            ("fc-models.example.com", .publicInternet),
            ("fe80.example.com", .publicInternet),
            ("feb.example.com", .publicInternet),
            // `fd::1` is 00fd::1, outside fc00::/7, even though its text starts with "fd".
            ("fd::1", .publicInternet),
            ("fc00::1", .localNetwork),
            ("[fd00::1]", .localNetwork),
            ("febf::1", .localNetwork),
            ("fec0::1", .publicInternet),
            ("fe80::1%en0", .localNetwork),
            ("0:0:0:0:0:0:0:1", .loopback),
            ("2001:db8::1", .publicInternet)
        ]

        for expectation in expectations {
            XCTAssertEqual(
                OpenAICompatibleEndpointConfiguration.hostScope(for: expectation.host),
                expectation.scope,
                expectation.host
            )
        }
    }

    // MARK: - Normalization and validation

    func test_init_normalizesSchemeTrailingSlashesAndModelName() throws {
        let configuration = try OpenAICompatibleEndpointConfiguration(
            baseURLString: "HTTPS://models.example.com/custom/v1///",
            modelName: "  gemma4  ",
            apiMode: .completions
        )

        XCTAssertEqual(configuration.baseURL.absoluteString, "https://models.example.com/custom/v1")
        XCTAssertEqual(configuration.modelName, "gemma4")
        XCTAssertEqual(configuration.apiMode, .completions)
        XCTAssertEqual(configuration.hostScope, .publicInternet)
    }

    func test_init_rejectsEmbeddedCredentials() {
        // Credentials in the URL would be logged and persisted in plain UserDefaults; the API key
        // belongs in the Keychain-backed credential store instead.
        XCTAssertThrowsError(
            try OpenAICompatibleEndpointConfiguration(
                baseURLString: "https://user:secret@models.example.com/v1",
                modelName: "m",
                apiMode: .completions
            )
        ) { error in
            XCTAssertEqual(error as? OpenAICompatibleEndpointError, .invalidBaseURL)
        }
    }

    func test_defaultOllamaGenerateURL_isOnlyOfferedForTheExactDefaultEndpoint() throws {
        let localDefault = try OpenAICompatibleEndpointConfiguration(
            baseURLString: OpenAICompatibleEndpointConfiguration.defaultBaseURLString,
            modelName: "m",
            apiMode: .completions
        )
        let otherLoopbackPort = try OpenAICompatibleEndpointConfiguration(
            baseURLString: "http://127.0.0.1:1234/v1",
            modelName: "m",
            apiMode: .completions
        )

        XCTAssertEqual(localDefault.defaultOllamaGenerateURL?.absoluteString, "http://127.0.0.1:11434/api/generate")
        // LM Studio and friends on another loopback port must not receive Ollama-only requests.
        XCTAssertNil(otherLoopbackPort.defaultOllamaGenerateURL)
    }

    func test_privacyWarning_namesWhereTypedTextGoes() throws {
        let lan = try OpenAICompatibleEndpointConfiguration(
            baseURLString: "http://10.0.0.5:8000/v1",
            modelName: "m",
            apiMode: .completions
        )
        let lanHTTPS = try OpenAICompatibleEndpointConfiguration(
            baseURLString: "https://10.0.0.5:8443/v1",
            modelName: "m",
            apiMode: .completions
        )
        let hosted = try OpenAICompatibleEndpointConfiguration(
            baseURLString: "https://models.example.com/v1",
            modelName: "m",
            apiMode: .completions
        )

        // Plain HTTP is allowed only on the LAN, so that is where the bearer token can travel in
        // cleartext; the warning has to say so before the user approves the server with Connect.
        XCTAssertEqual(
            lan.privacyWarning,
            "Cotabby will send typed text, any enabled context, and your API key, if you entered one, " +
                "to this server on your local network without encryption."
        )
        XCTAssertEqual(
            lanHTTPS.privacyWarning,
            "Cotabby will send typed text and any enabled context to this server on your local network."
        )
        XCTAssertEqual(
            hosted.privacyWarning,
            "This server is outside your Mac. Typed text and any enabled context will leave your device."
        )
    }

    // MARK: - Route, state, and error vocabulary

    func test_apiMode_routesAreRelativeToTheBaseURL() {
        XCTAssertEqual(OpenAICompatibleAPIMode.completions.route, "completions")
        XCTAssertEqual(OpenAICompatibleAPIMode.chatCompletions.route, "chat/completions")
        // Raw values are persisted under `cotabbyOpenAICompatibleAPIMode`.
        XCTAssertEqual(OpenAICompatibleAPIMode.allCases.map(\.rawValue), ["completions", "chatCompletions"])
    }

    func test_connectionState_summaryPluralizesModelCountAndExposesFailureDetail() {
        XCTAssertEqual(OpenAICompatibleConnectionState.idle.summary, "Not connected")
        XCTAssertEqual(OpenAICompatibleConnectionState.connecting.summary, "Connecting…")
        XCTAssertEqual(OpenAICompatibleConnectionState.ready(modelCount: 1).summary, "Connected · 1 model")
        XCTAssertEqual(OpenAICompatibleConnectionState.ready(modelCount: 3).summary, "Connected · 3 models")
        XCTAssertEqual(OpenAICompatibleConnectionState.failed("Timed out").summary, "Timed out")

        XCTAssertEqual(OpenAICompatibleConnectionState.failed("Timed out").failureDetail, "Timed out")
        XCTAssertNil(OpenAICompatibleConnectionState.ready(modelCount: 2).failureDetail)
        XCTAssertNil(OpenAICompatibleConnectionState.idle.failureDetail)
    }

    func test_endpointErrors_haveDistinctUserFacingDescriptions() {
        let descriptions = [
            OpenAICompatibleEndpointError.invalidBaseURL,
            .insecurePublicHTTP,
            .emptyModelName,
            .unapprovedServer("https://models.example.com/v1")
        ].compactMap(\.errorDescription)

        XCTAssertEqual(descriptions.count, 4)
        XCTAssertEqual(Set(descriptions).count, 4)
        XCTAssertEqual(
            OpenAICompatibleEndpointError.insecurePublicHTTP.errorDescription,
            "Public endpoints must use HTTPS. HTTP is limited to this Mac or the local network."
        )
        // Names the server so the user can recognize it, or refuse it, before pressing Connect.
        XCTAssertEqual(
            OpenAICompatibleEndpointError.unapprovedServer("https://models.example.com/v1").errorDescription,
            "Press Connect to confirm https://models.example.com/v1 before Cotabby sends it any text."
        )
    }
}
