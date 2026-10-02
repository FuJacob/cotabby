import Foundation
import XCTest
@testable import Cotabby

/// Drives the real coordinator to pin that per-app behavior reaches the generation gate: with
/// mid-line completions off in an app, text after the caret on the same line means no request.
@MainActor
final class SuggestionCoordinatorPerAppTests: XCTestCase {
    private let app = "com.example.TestApp"

    private func requestCount(midLine: PerAppToggle, trailingText: String) async -> Int {
        let rig = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(
                bundleIdentifier: app, precedingText: "Hello ", trailingText: trailingText
            ),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
                debounceMilliseconds: 1,
                perAppBehaviors: [app: PerAppBehavior(midLineCompletions: midLine)]
            )
        )
        defer { rig.coordinator.stop() }
        rig.engine.resultProvider = { request in
            SuggestionResult(generation: request.generation, rawText: "there", text: "there", latency: 0.01)
        }
        rig.coordinator.schedulePrediction()
        // Give an allowed request time to arrive; a blocked one never does.
        try? await Task.sleep(nanoseconds: 200_000_000)
        return rig.engine.requests.count
    }

    func test_midLineOffSkipsRequestsWhenTextFollowsOnTheLine() async {
        let blocked = await requestCount(midLine: .off, trailingText: "world")
        XCTAssertEqual(blocked, 0)
    }

    func test_midLineOffStillSuggestsAtTheEndOfALine() async {
        let allowed = await requestCount(midLine: .off, trailingText: "")
        XCTAssertGreaterThan(allowed, 0)
    }

    func test_midLineDefaultSuggestsWithTextAfterTheCaret() async {
        let allowed = await requestCount(midLine: .useDefault, trailingText: "world")
        XCTAssertGreaterThan(allowed, 0)
    }
}
