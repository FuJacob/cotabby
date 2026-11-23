import Foundation
import XCTest
@testable import Cotabby

/// Pins what counts as "the same server" for the endpoint. Too loose and text can reach a server the
/// user never confirmed; too strict and a harmless respelling of the URL asks the user to confirm
/// their own server again.
final class OpenAICompatibleEndpointOriginTests: XCTestCase {
    func test_spellingsOfOneServerShareAnOrigin() throws {
        let groups: [[String]] = [
            [
                "https://models.example.com",
                "HTTPS://Models.Example.COM/v1/",
                "https://models.example.com:443/custom/v1",
                "https://models.example.com/v1///"
            ],
            [
                "http://127.0.0.1:11434/v1",
                "http://127.0.0.1:11434",
                "HTTP://127.0.0.1:11434/"
            ],
            [
                "http://[::1]:8080/v1",
                "http://[::1]:8080"
            ],
            [
                "http://ollama.local",
                "http://ollama.local:80/v1"
            ]
        ]

        for group in groups {
            let origins = try group.map { try XCTUnwrap(origin($0), $0) }
            for (spelling, candidate) in zip(group, origins) {
                XCTAssertEqual(candidate, origins[0], "\(spelling) vs \(group[0])")
                XCTAssertEqual(candidate.serialized, origins[0].serialized, spelling)
            }
        }
    }

    func test_schemeHostAndPortEachDistinguishServers() throws {
        let base = try XCTUnwrap(origin("https://models.example.com/v1"))
        let different = [
            "http://models.example.com/v1",
            "https://models.example.com:8443/v1",
            "https://evil.example.com/v1",
            "https://models.example.com.evil.example/v1",
            "https://example.com/v1"
        ]

        for spelling in different {
            XCTAssertNotEqual(try XCTUnwrap(origin(spelling), spelling), base, spelling)
        }
    }

    func test_serializedFormHasExplicitPortAndBracketsIPv6() throws {
        XCTAssertEqual(try XCTUnwrap(origin("https://Models.Example.com/v1")).serialized, "https://models.example.com:443")
        XCTAssertEqual(try XCTUnwrap(origin("http://localhost/v1")).serialized, "http://localhost:80")
        XCTAssertEqual(try XCTUnwrap(origin("http://127.0.0.1:11434/v1")).serialized, "http://127.0.0.1:11434")

        let ipv6 = try XCTUnwrap(origin("http://[FD00::1]:8000/v1"))
        XCTAssertEqual(ipv6.host, "fd00::1", "Brackets are URL syntax, not part of the host")
        XCTAssertEqual(ipv6.serialized, "http://[fd00::1]:8000")
    }

    func test_nonHTTPAndHostlessURLsHaveNoOrigin() {
        for spelling in ["file:///tmp/model", "ftp://127.0.0.1/v1", "mailto:someone@example.com", "/relative/path"] {
            XCTAssertNil(origin(spelling), spelling)
        }
    }

    private func origin(_ spelling: String) -> OpenAICompatibleEndpointOrigin? {
        URL(string: spelling).flatMap(OpenAICompatibleEndpointOrigin.init(url:))
    }
}
