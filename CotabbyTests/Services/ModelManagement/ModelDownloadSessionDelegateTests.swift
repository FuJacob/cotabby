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
        } catch let interruption as DownloadInterruption {
            XCTAssertEqual(interruption, .paused(resumeData: nil))
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

    /// Cancel outranks pause before the attempt starts, in either order.
    func test_cancelWinsOverPauseBeforeDownload() async {
        for pauseFirst in [true, false] {
            let delegate = ModelDownloadSessionDelegate { _ in }
            if pauseFirst {
                delegate.pause()
                delegate.cancel()
            } else {
                delegate.cancel()
                delegate.pause()
            }

            do {
                _ = try await delegate.download(from: URL(string: "https://example.com/model.gguf")!)
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("pauseFirst \(pauseFirst): unexpected error \(error)")
            }
        }
    }

    /// Drives the whole attempt through real URLSession callbacks against a local file, so the
    /// idle, active and resolved phases are exercised without any network access.
    func test_downloadOfALocalFileResolvesWithTheRescuedFile() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("cotabby-delegate-source-\(UUID().uuidString).gguf")
        try Data("model bytes".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let delegate = ModelDownloadSessionDelegate { _ in }

        let result = try await delegate.download(from: source)
        defer { try? FileManager.default.removeItem(at: result.temporaryURL) }

        XCTAssertEqual(try Data(contentsOf: result.temporaryURL), Data("model bytes".utf8))

        // A stop request after resolution has nothing left to act on and must not crash or
        // resume the continuation a second time.
        delegate.pause()
        delegate.cancel()
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
