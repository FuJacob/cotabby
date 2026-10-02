import XCTest
@testable import Cotabby

/// The pure half of `GPUStatisticsReader`: parsing the driver's `PerformanceStatistics` and
/// `AppUsage` dictionaries, and turning two cumulative GPU-time readings into a share of the GPU.
final class GPUStatisticsReaderTests: XCTestCase {
    func testDeviceStatisticsAreParsedAndUtilizationIsClamped() {
        let statistics: [String: Any] = [
            "Device Utilization %": NSNumber(value: 15),
            "In use system memory": NSNumber(value: UInt64(21_598_748_672))
        ]
        XCTAssertEqual(GPUStatisticsReader.deviceUtilizationPercent(from: statistics), 15)
        XCTAssertEqual(GPUStatisticsReader.inUseMemoryBytes(from: statistics), 21_598_748_672)
        XCTAssertEqual(
            GPUStatisticsReader.deviceUtilizationPercent(from: ["Device Utilization %": NSNumber(value: 140)]),
            100
        )
        XCTAssertNil(GPUStatisticsReader.deviceUtilizationPercent(from: nil))
        XCTAssertNil(GPUStatisticsReader.inUseMemoryBytes(from: [:]))
    }

    func testGPUTimeIsSummedOverEveryClientAndAPI() {
        // Shape measured on a live Cotabby Dev: one client with two Metal entries.
        let clients: [[[String: Any]]] = [
            [
                ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 0)],
                ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 1_651_666)]
            ],
            [["API": "Metal", "accumulatedGPUTime": NSNumber(value: 500)]]
        ]
        XCTAssertEqual(GPUStatisticsReader.accumulatedGPUTime(fromClients: clients), 1_652_166)
        XCTAssertEqual(GPUStatisticsReader.accumulatedGPUTime(fromClients: [[]]), 0)
        XCTAssertNil(GPUStatisticsReader.accumulatedGPUTime(fromClients: []), "no GPU client is no data, not 0%")
    }

    func testProcessShareIsGPUTimeOverWallTime() {
        // Measured: 1.84 s of GPU time in 2.01 s of wall time under a llama.cpp benchmark.
        let share = GPUStatisticsReader.processUtilizationPercent(
            previousNanoseconds: 1_000_000_000, currentNanoseconds: 2_836_202_166, elapsedSeconds: 2.01
        )
        XCTAssertEqual(try XCTUnwrap(share), 91.35, accuracy: 0.01)
        XCTAssertEqual(
            GPUStatisticsReader.processUtilizationPercent(previousNanoseconds: 0, currentNanoseconds: 3_000_000_000, elapsedSeconds: 1),
            100
        )
    }

    func testProcessShareIsUnknownWithoutTwoUsableReadings() {
        XCTAssertNil(GPUStatisticsReader.processUtilizationPercent(previousNanoseconds: nil, currentNanoseconds: 5, elapsedSeconds: 1))
        XCTAssertNil(GPUStatisticsReader.processUtilizationPercent(previousNanoseconds: 5, currentNanoseconds: nil, elapsedSeconds: 1))
        XCTAssertNil(GPUStatisticsReader.processUtilizationPercent(previousNanoseconds: 5, currentNanoseconds: 9, elapsedSeconds: 0))
        XCTAssertNil(
            GPUStatisticsReader.processUtilizationPercent(previousNanoseconds: 9, currentNanoseconds: 5, elapsedSeconds: 1),
            "a client closed on model reload drops its time; that is a reset, not negative usage"
        )
    }
}
