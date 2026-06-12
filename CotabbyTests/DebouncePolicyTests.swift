import XCTest
@testable import Cotabby

final class DebouncePolicyTests: XCTestCase {
    func testNoLatencyDataUsesFallback() {
        XCTAssertEqual(DebouncePolicy.milliseconds(lastGenerationLatencyMilliseconds: nil, fallback: 20), 20)
        XCTAssertEqual(DebouncePolicy.milliseconds(lastGenerationLatencyMilliseconds: 0, fallback: 20), 20)
    }

    func testFastGenerationsGetTheShortDebounce() {
        XCTAssertEqual(DebouncePolicy.milliseconds(lastGenerationLatencyMilliseconds: 45, fallback: 20), 15)
        XCTAssertEqual(DebouncePolicy.milliseconds(lastGenerationLatencyMilliseconds: 70, fallback: 20), 15)
    }

    func testMediumGenerationsGetTheMiddleDebounce() {
        XCTAssertEqual(DebouncePolicy.milliseconds(lastGenerationLatencyMilliseconds: 71, fallback: 20), 25)
        XCTAssertEqual(DebouncePolicy.milliseconds(lastGenerationLatencyMilliseconds: 140, fallback: 20), 25)
    }

    func testSlowGenerationsBackOff() {
        XCTAssertEqual(DebouncePolicy.milliseconds(lastGenerationLatencyMilliseconds: 141, fallback: 20), 55)
        XCTAssertEqual(DebouncePolicy.milliseconds(lastGenerationLatencyMilliseconds: 900, fallback: 20), 55)
    }
}
