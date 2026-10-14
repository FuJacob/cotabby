import XCTest
@testable import Cotabby

/// Formatting of the menu bar's "Cotabby uses ..." line, plus the sampler's independence from the
/// shared CPU baseline.
final class ResourceUsageSummaryTests: XCTestCase {
    private func summary(
        cpu: Double = 34.2, bytes: UInt64 = 2_684_354_560, gpu: Double? = 12.4, mlx: Bool = false
    ) -> ResourceUsageSummary {
        ResourceUsageSummary(cpuPercent: cpu, memoryBytes: bytes, gpuPercent: gpu, includesMLXServer: mlx)
    }

    func testFullLine() {
        XCTAssertEqual(
            ResourceUsageSummary.menuLine(summary()), "Cotabby uses  CPU 34% · RAM 2.5 GB · GPU 12%")
    }

    func testMLXSuffix() {
        XCTAssertTrue(ResourceUsageSummary.menuLine(summary(mlx: true)).hasSuffix("GPU 12% incl. MLX"))
    }

    func testUnknownGPUShowsDash() {
        XCTAssertTrue(ResourceUsageSummary.menuLine(summary(gpu: nil)).hasSuffix("GPU —"))
    }

    func testCPURoundsToWholePercentAndMayExceed100() {
        XCTAssertTrue(ResourceUsageSummary.menuLine(summary(cpu: 229.6)).contains("CPU 230%"))
        XCTAssertTrue(ResourceUsageSummary.menuLine(summary(cpu: 0.2)).contains("CPU 0%"))
    }

    func testMemoryUnits() {
        XCTAssertEqual(ResourceUsageSummary.memoryText(150 * 1_048_576), "150 MB")
        XCTAssertEqual(ResourceUsageSummary.memoryText(1_073_741_824), "1.0 GB")
        XCTAssertEqual(ResourceUsageSummary.memoryText(1_073_741_824 - 1), "1.0 GB", "rounds up to GB, never 1024 MB")
        XCTAssertEqual(ResourceUsageSummary.memoryText(0), "0 MB")
    }

    func testMenuSamplerDoesNotTouchTheSharedCPUBaseline() {
        let before = SystemResourceSampler.sharedBaseline.withLock { $0.count }
        let sampler = MenuResourceSampler()
        _ = sampler.sample(extraProcessID: getpid())
        XCTAssertEqual(SystemResourceSampler.sharedBaseline.withLock { $0.count }, before)
    }
}
