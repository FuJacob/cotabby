import XCTest
@testable import Cotabby

/// Tests for when Sparkle may start and when a launch checks for updates at once. Starting with an
/// unusable configuration shows Sparkle's misconfiguration alert, and a wrong catch-up rule either
/// checks on every launch or lets a long-closed app wait a day for its first check.
final class AppUpdateStartPolicyTests: XCTestCase {
    private static let feed = "https://updates.example.com/appcast.xml"
    private static let key = "dGVzdC1vbmx5LXNwYXJrbGUta2V5"

    func test_configurationProblem_acceptsAFeedAndARealKey() {
        XCTAssertNil(AppUpdateStartPolicy.configurationProblem(feedURL: Self.feed, publicKey: Self.key))
    }

    func test_configurationProblem_rejectsAMissingFeedBeforeLookingAtTheKey() {
        XCTAssertEqual(
            AppUpdateStartPolicy.configurationProblem(feedURL: nil, publicKey: nil),
            "Missing or invalid SUFeedURL."
        )
    }

    func test_configurationProblem_rejectsAMissingOrPlaceholderKey() {
        for publicKey in [nil, AppUpdateStartPolicy.publicKeyPlaceholder] {
            XCTAssertEqual(
                AppUpdateStartPolicy.configurationProblem(feedURL: Self.feed, publicKey: publicKey),
                "SUPublicEDKey is missing or still using the placeholder value.",
                String(describing: publicKey)
            )
        }
    }

    func test_needsCatchUpCheck_whenNothingWasEverChecked() {
        XCTAssertTrue(AppUpdateStartPolicy.needsCatchUpCheck(lastCheck: nil, now: Date()))
    }

    func test_needsCatchUpCheck_onlyOnceAFullIntervalHasPassed() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let interval = AppUpdateStartPolicy.automaticCheckInterval

        XCTAssertTrue(AppUpdateStartPolicy.needsCatchUpCheck(lastCheck: now.addingTimeInterval(-interval), now: now))
        XCTAssertFalse(AppUpdateStartPolicy.needsCatchUpCheck(lastCheck: now.addingTimeInterval(-interval + 1), now: now))
    }
}
