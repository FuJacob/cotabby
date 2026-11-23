import XCTest
@testable import Cotabby

final class DownloadStopIntentTests: XCTestCase {
    /// Cancel deletes the partial data, so it must win in either order; otherwise a late pause
    /// would publish a resumable state for a transfer whose bytes are being removed.
    func test_merging_table() {
        let cases: [(current: DownloadStopIntent?, requested: DownloadStopIntent, expected: DownloadStopIntent)] = [
            (nil, .pause, .pause),
            (nil, .cancel, .cancel),
            (.pause, .pause, .pause),
            (.pause, .cancel, .cancel),
            (.cancel, .pause, .cancel),
            (.cancel, .cancel, .cancel)
        ]
        for testCase in cases {
            XCTAssertEqual(
                DownloadStopIntent.merging(testCase.current, with: testCase.requested),
                testCase.expected,
                "\(String(describing: testCase.current)) then \(testCase.requested)"
            )
        }
    }
}
