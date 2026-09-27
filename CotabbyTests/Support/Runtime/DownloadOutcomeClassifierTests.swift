import XCTest
@testable import Cotabby

/// Tests for the rule that decides whether a download error is "the user pressed Cancel",
/// "the user pressed Pause", or "something went genuinely wrong."
///
/// This classification matters because user cancellation surfaces as different errors at runtime
/// (CancellationError vs URLError.cancelled depending on whether the URLSession download had started
/// yet, or Aria2DownloadError.cancelled on the aria2 path) but all of them should restore the prior
/// state, never surface as a user-visible failure. Conversely, a real failure misclassified as a
/// cancellation would silently roll back to idle and the user would never see the problem.
final class DownloadOutcomeClassifierTests: XCTestCase {
    func test_classification_table() {
        let cases: [(name: String, error: Error, cancellation: Bool, pause: Bool)] = [
            ("CancellationError", CancellationError(), true, false),
            ("URLError.cancelled", URLError(.cancelled), true, false),
            ("Aria2DownloadError.cancelled", Aria2DownloadError.cancelled, true, false),
            ("Aria2DownloadError.paused", Aria2DownloadError.paused, false, true),
            ("URLError.timedOut", URLError(.timedOut), false, false),
            ("URLError.notConnectedToInternet", URLError(.notConnectedToInternet), false, false),
            ("URLError.badServerResponse", URLError(.badServerResponse), false, false),
            ("Aria2DownloadError.executableNotFound", Aria2DownloadError.executableNotFound, false, false),
            (
                "Aria2DownloadError.processFailed",
                Aria2DownloadError.processFailed(exitCode: 7, message: "network"),
                false,
                false
            ),
            ("NSError", NSError(domain: "TestDomain", code: 42, userInfo: nil), false, false),
            (
                "LlamaRuntimeError.unavailable",
                LlamaRuntimeError.unavailable("Model download failed with status code 500."),
                false,
                false
            )
        ]
        for testCase in cases {
            XCTAssertEqual(
                DownloadOutcomeClassifier.isUserCancellation(testCase.error),
                testCase.cancellation,
                "isUserCancellation(\(testCase.name))"
            )
            XCTAssertEqual(
                DownloadOutcomeClassifier.isUserPause(testCase.error),
                testCase.pause,
                "isUserPause(\(testCase.name))"
            )
        }
    }
}
