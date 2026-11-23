import XCTest
@testable import Cotabby

/// Tests for the rule that decides whether a download error is "the user pressed Cancel",
/// "the user pressed Pause", or "something went genuinely wrong."
///
/// This classification matters because user cancellation surfaces as different errors at runtime
/// (CancellationError vs URLError.cancelled depending on whether the URLSession download had started
/// yet, or DownloadInterruption.cancelled when the request landed before a session opened) but all of
/// them should restore the prior state, never surface as a user-visible failure. Conversely, a real
/// failure misclassified as a cancellation would silently roll back to idle and the user would never
/// see the problem.
final class DownloadOutcomeClassifierTests: XCTestCase {
    func test_classification_table() {
        let resumeData = Data("resume".utf8)
        let cases: [(name: String, error: Error, expected: DownloadOutcomeClassifier.Stop)] = [
            ("CancellationError", CancellationError(), .cancelled),
            ("URLError.cancelled", URLError(.cancelled), .cancelled),
            ("DownloadInterruption.cancelled", DownloadInterruption.cancelled, .cancelled),
            ("DownloadInterruption.paused without data", DownloadInterruption.paused(resumeData: nil), .paused(resumeData: nil)),
            (
                "DownloadInterruption.paused with data",
                DownloadInterruption.paused(resumeData: resumeData),
                .paused(resumeData: resumeData)
            ),
            ("URLError.timedOut", URLError(.timedOut), .failed),
            ("URLError.notConnectedToInternet", URLError(.notConnectedToInternet), .failed),
            ("URLError.badServerResponse", URLError(.badServerResponse), .failed),
            ("ModelDownloadSessionError.alreadyStarted", ModelDownloadSessionError.alreadyStarted, .failed),
            ("NSError", NSError(domain: "TestDomain", code: 42, userInfo: nil), .failed),
            (
                "LlamaRuntimeError.unavailable",
                LlamaRuntimeError.unavailable("Model download failed with status code 500."),
                .failed
            )
        ]
        for testCase in cases {
            XCTAssertEqual(DownloadOutcomeClassifier.classify(testCase.error), testCase.expected, testCase.name)
        }
    }
}
