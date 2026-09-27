import XCTest
@testable import Cotabby

/// Locks the single-use download delegate's preflight state machine and its progress reporting.
/// URLSession callbacks are invoked directly against a never-resumed task, so no network is used.
final class ModelDownloadSessionDelegateTests: XCTestCase {
    func test_cancelBeforeDownloadPreventsTheRequestFromStarting() async {
        let delegate = ModelDownloadSessionDelegate { _ in }
        delegate.cancel()

        do {
            _ = try await delegate.download(from: URL(string: "https://example.com/model.gguf")!)
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: the preflight state wins before URLSession starts network work.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_pauseBeforeDownloadPreventsTheRequestFromStarting() async {
        let delegate = ModelDownloadSessionDelegate { _ in }
        delegate.pause()

        do {
            _ = try await delegate.download(from: URL(string: "https://example.com/model.gguf")!)
            XCTFail("Expected pause")
        } catch URLSessionDownloadInterruption.paused(let resumeData) {
            XCTAssertNil(resumeData)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_delegateRejectsASecondDownloadAttempt() async {
        let delegate = ModelDownloadSessionDelegate { _ in }
        delegate.cancel()

        do {
            _ = try await delegate.download(from: URL(string: "https://example.com/first.gguf")!)
        } catch is CancellationError {
            // The first attempt consumes the single-use delegate.
        } catch {
            return XCTFail("Unexpected first-attempt error: \(error)")
        }

        do {
            _ = try await delegate.download(from: URL(string: "https://example.com/second.gguf")!)
            XCTFail("Expected the delegate to reject reuse")
        } catch let error as ModelDownloadSessionError {
            XCTAssertEqual(error, .alreadyStarted)
        } catch {
            XCTFail("Unexpected second-attempt error: \(error)")
        }
    }

    /// Progress is a fraction only when the server declared a length; an unknown length reports
    /// nil so the UI shows an indeterminate bar instead of a bogus percentage.
    func test_progressCallbacks_reportFractionsOnlyForKnownLengths() {
        let recorder = ProgressRecorder()
        let delegate = ModelDownloadSessionDelegate { recorder.append($0) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://example.invalid/model.gguf")!)

        delegate.urlSession(session, downloadTask: task, didWriteData: 25, totalBytesWritten: 25, totalBytesExpectedToWrite: 100)
        delegate.urlSession(
            session,
            downloadTask: task,
            didWriteData: 10,
            totalBytesWritten: 35,
            totalBytesExpectedToWrite: NSURLSessionTransferSizeUnknown
        )
        delegate.urlSession(session, downloadTask: task, didResumeAtOffset: 50, expectedTotalBytes: 200)
        delegate.urlSession(session, downloadTask: task, didResumeAtOffset: 50, expectedTotalBytes: 0)

        XCTAssertEqual(recorder.values, [0.25, nil, 0.25, nil])
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double?] = []

    var values: [Double?] {
        lock.withLock { storage }
    }

    func append(_ value: Double?) {
        lock.withLock { storage.append(value) }
    }
}
