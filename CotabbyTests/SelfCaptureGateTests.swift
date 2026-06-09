import XCTest
@testable import Cotabby

/// Tests for `SelfCaptureGate`, the rule that keeps Cotabby from completing inside its own UI while
/// allowing the one sanctioned exception (the Context pane's live-preview field). This is the safety
/// boundary the live-preview feature rests on, so it is pinned directly: other settings fields must
/// never become completion targets.
final class SelfCaptureGateTests: XCTestCase {
    private let selfBundle = "com.cotabby.app"
    private let previewIdentifier = "com.cotabby.settings.context.live-preview"

    func test_otherApp_isAlwaysAllowed() {
        XCTAssertTrue(SelfCaptureGate.allowsCapture(
            focusedBundleIdentifier: "com.apple.TextEdit",
            ignoredBundleIdentifier: selfBundle,
            focusedElementIdentifier: nil,
            sanctionedElementIdentifier: previewIdentifier
        ))
    }

    /// The element identifier (an AX read in production) must not be evaluated for other apps, which
    /// is the common path run on every poll tick.
    func test_otherApp_doesNotEvaluateElementIdentifier() {
        let probe = EvaluationProbe()
        _ = SelfCaptureGate.allowsCapture(
            focusedBundleIdentifier: "com.apple.TextEdit",
            ignoredBundleIdentifier: selfBundle,
            focusedElementIdentifier: probe.read(),
            sanctionedElementIdentifier: previewIdentifier
        )
        XCTAssertEqual(probe.count, 0)
    }

    func test_self_previewField_isAllowed() {
        XCTAssertTrue(SelfCaptureGate.allowsCapture(
            focusedBundleIdentifier: selfBundle,
            ignoredBundleIdentifier: selfBundle,
            focusedElementIdentifier: previewIdentifier,
            sanctionedElementIdentifier: previewIdentifier
        ))
    }

    func test_self_otherField_isBlocked() {
        XCTAssertFalse(SelfCaptureGate.allowsCapture(
            focusedBundleIdentifier: selfBundle,
            ignoredBundleIdentifier: selfBundle,
            focusedElementIdentifier: "com.cotabby.settings.search",
            sanctionedElementIdentifier: previewIdentifier
        ))
    }

    func test_self_unreadableIdentifier_isBlocked() {
        XCTAssertFalse(SelfCaptureGate.allowsCapture(
            focusedBundleIdentifier: selfBundle,
            ignoredBundleIdentifier: selfBundle,
            focusedElementIdentifier: nil,
            sanctionedElementIdentifier: previewIdentifier
        ))
    }

    func test_noSanctionedIdentifier_blocksAllSelfCapture() {
        XCTAssertFalse(SelfCaptureGate.allowsCapture(
            focusedBundleIdentifier: selfBundle,
            ignoredBundleIdentifier: selfBundle,
            focusedElementIdentifier: previewIdentifier,
            sanctionedElementIdentifier: nil
        ))
    }

    /// Counts how many times its `read()` result is actually evaluated, to prove the autoclosure stays
    /// lazy for the non-self path.
    private final class EvaluationProbe {
        private(set) var count = 0
        func read() -> String? {
            count += 1
            return nil
        }
    }
}
