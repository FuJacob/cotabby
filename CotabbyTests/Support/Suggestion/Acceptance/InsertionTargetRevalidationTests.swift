import XCTest
@testable import Cotabby

/// Pure tests for the pre-post focus re-check: synthetic events are refused when keyboard focus has
/// left the validated app or a secure field holds it, and still allowed in the shapes where a fresh
/// read legitimately disagrees with the snapshot (no AX answer, a system agent shadowing focus).
final class InsertionTargetRevalidationTests: XCTestCase {
    private let target = InsertionTarget(processIdentifier: 100, bundleIdentifier: "com.example.Editor")

    private func observation(
        secure: Bool = false,
        focusedPID: pid_t? = 100,
        focusedBundle: String? = "com.example.Editor",
        frontmostPID: pid_t? = 100,
        frontmostBundle: String? = "com.example.Editor"
    ) -> InsertionTargetObservation {
        InsertionTargetObservation(
            isSecureEventInputEnabled: secure,
            focusedProcessIdentifier: focusedPID,
            focusedBundleIdentifier: focusedBundle,
            frontmostProcessIdentifier: frontmostPID,
            frontmostBundleIdentifier: frontmostBundle
        )
    }

    private func verdict(_ observation: InsertionTargetObservation) -> InsertionTargetRevalidation.Verdict {
        InsertionTargetRevalidation.verdict(target: target, observation: observation)
    }

    func test_focusStillInTheValidatedAppProceeds() {
        XCTAssertEqual(verdict(observation()), .proceed)
    }

    func test_accessoryPanelOwningFocusWhileAnotherAppIsFrontmostProceeds() {
        // Spotlight/Raycast-style panels own the focused field without becoming frontmost. The
        // validated target is the panel's app, so the owner pid, not the frontmost app, decides.
        let raycast = InsertionTarget(processIdentifier: 300, bundleIdentifier: "com.raycast.macos")
        let live = observation(focusedPID: 300, focusedBundle: "com.raycast.macos")

        XCTAssertEqual(InsertionTargetRevalidation.verdict(target: raycast, observation: live), .proceed)
    }

    func test_secureInputRefusesEvenInTheValidatedApp() {
        guard case .abort = verdict(observation(secure: true)) else {
            return XCTFail("A password field gaining focus inside the same app must still refuse the insert")
        }
    }

    func test_focusMovedToAnotherAppRefuses() {
        let live = observation(focusedPID: 200, focusedBundle: "com.example.Other", frontmostPID: 200,
                               frontmostBundle: "com.example.Other")

        guard case .abort = verdict(live) else {
            return XCTFail("Events posted now would land in another app")
        }
    }

    func test_noAccessibilityAnswerProceeds() {
        // Chromium fields reached only by hit-test, and hosts that hit the messaging timeout, give no
        // answer here; refusing would break accept in those hosts outright.
        XCTAssertEqual(verdict(observation(focusedPID: nil, focusedBundle: nil)), .proceed)
    }

    func test_systemAgentShadowingFocusOverTheValidatedFrontmostAppProceeds() {
        // A privacy prompt can own the system-wide focused element while the frontmost app keeps
        // receiving keystrokes; FocusTracker validated the frontmost app's own field.
        let live = observation(focusedPID: 50, focusedBundle: "com.apple.UserNotificationCenter")

        XCTAssertEqual(verdict(live), .proceed)
    }

    func test_systemAgentShadowingADifferentFrontmostAppRefuses() {
        let live = observation(
            focusedPID: 50, focusedBundle: "com.apple.UserNotificationCenter",
            frontmostPID: 200, frontmostBundle: "com.example.Other"
        )

        guard case .abort = verdict(live) else {
            return XCTFail("The shadow exception only keeps a target that is itself frontmost")
        }
    }

    func test_ordinaryAppTakingFocusIsNotTreatedAsAShadow() {
        // Only the named system agents shadow focus; any other app taking it is a real focus change.
        let live = observation(focusedPID: 200, focusedBundle: "com.example.Other")

        guard case .abort = verdict(live) else {
            return XCTFail("A non-agent app owning focus means the events would land there")
        }
    }

    func test_targetIsTakenFromTheValidatedSnapshot() {
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(
            bundleIdentifier: "com.example.Mail", processIdentifier: 777
        )

        XCTAssertEqual(
            InsertionTarget(snapshot: snapshot),
            InsertionTarget(processIdentifier: 777, bundleIdentifier: "com.example.Mail")
        )
    }
}
