import XCTest
@testable import Cotabby

/// Pins the pane's latency figures: nearest-rank median and 95th percentile over the most recent
/// samples only, with nonsense timings ignored.
final class MemoryLatencyStatsTests: XCTestCase {
    func test_medianAndP95ComeFromTheRecentSamples() {
        var stats = MemoryLatencyStats()
        XCTAssertNil(stats.median)
        for value in 1...100 { stats.record(Double(value)) }
        XCTAssertEqual(stats.median, 51)
        XCTAssertEqual(stats.p95, 95)
        for _ in 0..<100 { stats.record(10) }
        XCTAssertEqual(stats.median, 10, "the older, slower samples have rolled off")
        XCTAssertEqual(stats.samples.count, MemoryLatencyStats.capacity)
        XCTAssertEqual(stats.total, 200)
        stats.record(.nan)
        stats.record(-1)
        XCTAssertEqual(stats.total, 200, "impossible timings are not recorded")
    }
}
