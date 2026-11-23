import Foundation
import XCTest
@testable import Cotabby

/// Pins the endpoint approval rule: a request goes only to the server the user approved with
/// Connect, and the one-time upgrade adoption runs only when no record exists at all. A wrong row
/// here either sends the user's text to a server they never confirmed or silently stops an existing
/// endpoint user's suggestions after an update.
@MainActor
final class OpenAICompatibleOriginApprovalPolicyTests: XCTestCase {
    // MARK: - Record encoding

    func test_recordRoundTripsAndTheSentinelMeansNothingApproved() {
        XCTAssertEqual(OpenAICompatibleOriginApproval(record: "none"), .nothingApproved)
        XCTAssertEqual(OpenAICompatibleOriginApproval.nothingApproved.record, "none")

        let approved = OpenAICompatibleOriginApproval.approved(origin: "https://models.example.com:443")
        XCTAssertEqual(OpenAICompatibleOriginApproval(record: approved.record), approved)
    }

    // MARK: - Request gate

    func test_allows_onlyTheApprovedServerRegardlessOfPathCaseOrDefaultPort() throws {
        let approval = OpenAICompatibleOriginApproval.approved(origin: "https://models.example.com:443")
        for spelling in [
            "https://models.example.com/v1",
            "HTTPS://Models.Example.com/custom/v1/",
            "https://models.example.com:443"
        ] {
            XCTAssertTrue(
                OpenAICompatibleOriginApprovalPolicy.allows(try configuration(spelling), approval: approval),
                spelling
            )
        }

        for spelling in [
            "https://other.example.com/v1",
            "https://models.example.com:8443/v1",
            "http://10.0.0.5/v1"
        ] {
            XCTAssertFalse(
                OpenAICompatibleOriginApprovalPolicy.allows(try configuration(spelling), approval: approval),
                spelling
            )
        }
    }

    func test_allows_schemeChangeOnTheSameHostNeedsApproval() throws {
        let approval = OpenAICompatibleOriginApproval.approved(origin: "http://10.0.0.5:80")
        XCTAssertTrue(OpenAICompatibleOriginApprovalPolicy.allows(try configuration("http://10.0.0.5/v1"), approval: approval))
        XCTAssertFalse(OpenAICompatibleOriginApprovalPolicy.allows(try configuration("https://10.0.0.5/v1"), approval: approval))
    }

    func test_allows_nothingWhenNothingIsApproved() throws {
        let local = try configuration(OpenAICompatibleEndpointConfiguration.defaultBaseURLString)
        XCTAssertFalse(
            OpenAICompatibleOriginApprovalPolicy.allows(local, approval: .nothingApproved),
            "Even the default loopback server needs one Connect"
        )
        XCTAssertFalse(
            OpenAICompatibleOriginApprovalPolicy.allows(local, approval: .approved(origin: "not an origin")),
            "An unreadable record approves nothing"
        )
    }

    // MARK: - Launch restoration

    func test_restore_existingRecordWinsAndIsNotRewritten() {
        let approved = OpenAICompatibleOriginApprovalPolicy.restore(
            storedRecord: "http://127.0.0.1:11434",
            configuredBaseURL: "https://elsewhere.example.com/v1",
            endpointInUse: true
        )
        XCTAssertEqual(approved.approval, .approved(origin: "http://127.0.0.1:11434"))
        XCTAssertNil(approved.recordToPersist)

        // The adoption is one-shot: once a sentinel exists, rewriting the defaults to select the
        // endpoint and point it somewhere new does not approve that server.
        let sentinel = OpenAICompatibleOriginApprovalPolicy.restore(
            storedRecord: "none",
            configuredBaseURL: "https://elsewhere.example.com/v1",
            endpointInUse: true
        )
        XCTAssertEqual(sentinel.approval, .nothingApproved)
        XCTAssertNil(sentinel.recordToPersist)
    }

    func test_restore_upgradingEndpointUserAdoptsTheConfiguredServerOnce() {
        let restoration = OpenAICompatibleOriginApprovalPolicy.restore(
            storedRecord: nil,
            configuredBaseURL: "http://192.168.1.50:8000/v1/",
            endpointInUse: true
        )
        XCTAssertEqual(restoration.approval, .approved(origin: "http://192.168.1.50:8000"))
        XCTAssertEqual(restoration.recordToPersist, "http://192.168.1.50:8000")
    }

    func test_restore_everyoneElseRecordsTheSentinel() {
        let notUsingEndpoint = OpenAICompatibleOriginApprovalPolicy.restore(
            storedRecord: nil,
            configuredBaseURL: OpenAICompatibleEndpointConfiguration.defaultBaseURLString,
            endpointInUse: false
        )
        XCTAssertEqual(notUsingEndpoint.approval, .nothingApproved)
        XCTAssertEqual(notUsingEndpoint.recordToPersist, "none")

        let invalidURL = OpenAICompatibleOriginApprovalPolicy.restore(
            storedRecord: nil,
            configuredBaseURL: "http://models.example.com/v1",
            endpointInUse: true
        )
        XCTAssertEqual(invalidURL.approval, .nothingApproved, "A URL Cotabby would refuse is never adopted")
        XCTAssertEqual(invalidURL.recordToPersist, "none")
    }

    func test_endpointInUse_coversTheSelectedEngineAndActivePowerProfiles() {
        XCTAssertTrue(endpointInUse(selected: .openAICompatible))
        XCTAssertFalse(endpointInUse(selected: .llamaOpenSource))
        XCTAssertTrue(endpointInUse(selected: .appleIntelligence, switching: true, battery: .openAICompatible))
        XCTAssertTrue(endpointInUse(selected: .llamaOpenSource, switching: true, pluggedIn: .openAICompatible))
        XCTAssertFalse(
            endpointInUse(selected: .llamaOpenSource, switching: false, battery: .openAICompatible),
            "A profile that power switching never applies does not count"
        )
    }

    // MARK: - Helpers

    private func configuration(_ baseURL: String) throws -> OpenAICompatibleEndpointConfiguration {
        try OpenAICompatibleEndpointConfiguration(baseURLString: baseURL, modelName: "m", apiMode: .chatCompletions)
    }

    private func endpointInUse(
        selected: SuggestionEngineKind,
        switching: Bool = false,
        battery: SuggestionEngineKind = .llamaOpenSource,
        pluggedIn: SuggestionEngineKind = .llamaOpenSource
    ) -> Bool {
        OpenAICompatibleOriginApprovalPolicy.endpointInUse(
            selectedEngine: selected,
            isPowerBasedModelSwitchingEnabled: switching,
            batteryEngine: battery,
            pluggedInEngine: pluggedIn
        )
    }
}
