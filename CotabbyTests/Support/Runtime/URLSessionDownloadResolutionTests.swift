import XCTest
@testable import Cotabby

/// Table for how a finished URLSession attempt resolves: every stop intent against every
/// combination of rescued file, response, failure and resume data the delegate can hold.
final class URLSessionDownloadResolutionTests: XCTestCase {
    private enum Expected: Equatable {
        case file
        case paused(Data?)
        case cancelled
        case failed(URLError.Code)
        case badResponse
    }

    private let fileURL = URL(fileURLWithPath: "/tmp/cotabby-resolution-test.gguf")
    private let response = URLResponse(
        url: URL(fileURLWithPath: "/tmp/source.gguf"), mimeType: nil, expectedContentLength: 4, textEncodingName: nil
    )
    private let resumeData = Data("resume".utf8)

    private func facts(
        file: Bool = false,
        response hasResponse: Bool = false,
        failure: URLError.Code? = nil,
        resumeData: Data? = nil
    ) -> URLSessionDownloadResolution.Facts {
        URLSessionDownloadResolution.Facts(
            fileURL: file ? fileURL : nil,
            response: hasResponse ? response : nil,
            failure: failure.map { URLError($0) },
            resumeData: resumeData
        )
    }

    private func resolve(_ intent: DownloadStopIntent?, _ facts: URLSessionDownloadResolution.Facts) -> Expected {
        switch URLSessionDownloadResolution.outcome(intent: intent, facts: facts) {
        case .file(let url, _):
            XCTAssertEqual(url, fileURL)
            return .file
        case .paused(let resumeData):
            return .paused(resumeData)
        case .cancelled:
            return .cancelled
        case .failed(let error):
            return .failed((error as? URLError)?.code ?? .unknown)
        case .badResponse:
            return .badResponse
        }
    }

    func test_noStopIntent() {
        XCTAssertEqual(resolve(nil, facts(file: true, response: true)), .file)
        XCTAssertEqual(resolve(nil, facts(failure: .timedOut)), .failed(.timedOut))
        XCTAssertEqual(
            resolve(nil, facts(file: true, response: true, failure: .networkConnectionLost)),
            .failed(.networkConnectionLost),
            "A transport error outranks a rescued file"
        )
        XCTAssertEqual(
            resolve(nil, facts(failure: .cancelled)),
            .cancelled,
            "Task cancellation reaches the session without a recorded intent and must not read as a failure"
        )
        XCTAssertEqual(resolve(nil, facts()), .badResponse)
        XCTAssertEqual(resolve(nil, facts(file: true)), .badResponse, "A file without a response cannot be validated")
        XCTAssertEqual(resolve(nil, facts(response: true)), .badResponse)
    }

    func test_pauseIntent() {
        XCTAssertEqual(resolve(.pause, facts(failure: .cancelled, resumeData: resumeData)), .paused(resumeData))
        XCTAssertEqual(resolve(.pause, facts(failure: .cancelled)), .paused(nil))
        XCTAssertEqual(
            resolve(.pause, facts(failure: .timedOut, resumeData: resumeData)),
            .paused(resumeData),
            "Once the user paused, whatever error ended the task is the pause taking effect"
        )
        XCTAssertEqual(resolve(.pause, facts(file: true)), .paused(nil), "A file without a response is not complete")
    }

    /// The pause-races-finish case: the complete file was already rescued when the pause landed.
    func test_pauseAfterTheFileCompletedReturnsTheFile() {
        XCTAssertEqual(resolve(.pause, facts(file: true, response: true)), .file)
        XCTAssertEqual(resolve(.pause, facts(file: true, response: true, failure: .cancelled, resumeData: resumeData)), .file)
    }

    func test_cancelIntentAlwaysCancels() {
        let everything = [
            facts(),
            facts(file: true, response: true),
            facts(failure: .timedOut),
            facts(failure: .cancelled, resumeData: resumeData),
            facts(file: true, response: true, failure: .cancelled)
        ]
        for candidate in everything {
            XCTAssertEqual(resolve(.cancel, candidate), .cancelled)
        }
    }
}
