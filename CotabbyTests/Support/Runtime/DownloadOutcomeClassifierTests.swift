import XCTest
@testable import Cotabby

/// Tests for the rule that decides whether a download error is "the user
/// pressed Cancel" or "something went genuinely wrong."
///
/// This classification matters because the two cases produce different errors
/// at runtime (CancellationError vs URLError.cancelled depending on whether
/// the URLSession download had started yet) but both should restore the prior
/// state, never surface as a user-visible failure.
final class DownloadOutcomeClassifierTests: XCTestCase {

    // MARK: - cancellation surfaces

    func test_isUserCancellation_trueForCancellationError() {
        XCTAssertTrue(DownloadOutcomeClassifier.isUserCancellation(CancellationError()))
    }

    func test_isUserCancellation_trueForURLErrorCancelled() {
        XCTAssertTrue(DownloadOutcomeClassifier.isUserCancellation(URLError(.cancelled)))
    }

    // MARK: - real failures

    func test_isUserCancellation_falseForURLErrorTimedOut() {
        XCTAssertFalse(DownloadOutcomeClassifier.isUserCancellation(URLError(.timedOut)))
    }

    func test_isUserCancellation_falseForURLErrorNotConnected() {
        XCTAssertFalse(DownloadOutcomeClassifier.isUserCancellation(URLError(.notConnectedToInternet)))
    }

    func test_isUserCancellation_falseForURLErrorBadServerResponse() {
        XCTAssertFalse(DownloadOutcomeClassifier.isUserCancellation(URLError(.badServerResponse)))
    }

    func test_isUserCancellation_falseForGenericNSError() {
        let error = NSError(domain: "TestDomain", code: 42, userInfo: nil)
        XCTAssertFalse(DownloadOutcomeClassifier.isUserCancellation(error))
    }

    /// Important: a domain-level runtime error (model unavailable, etc.) must
    /// NOT be misclassified as a cancellation. Otherwise a real failure would
    /// silently roll back to .idle and the user would never see the problem.
    func test_isUserCancellation_falseForLlamaRuntimeError() {
        XCTAssertFalse(DownloadOutcomeClassifier.isUserCancellation(
            LlamaRuntimeError.unavailable("Model download failed with status code 500.")
        ))
    }
}
