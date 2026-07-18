import XCTest
@testable import Cotabby

/// The probe is the seam between real host hardware and the pure
/// `OnboardingTemplateRecommender`, so these tests pin its two outputs to the
/// authoritative sources they must mirror.
final class HardwareCapabilityProbeTests: XCTestCase {
    func test_current_reportsHostPhysicalMemoryExactly() {
        let capability = HardwareCapabilityProbe.current()

        XCTAssertEqual(capability.physicalMemoryBytes, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(capability.physicalMemoryBytes, 0)
    }

    func test_current_derivedGigabytesMatchInstalledMemoryScale() {
        let capability = HardwareCapabilityProbe.current()

        // Sanity bounds, not exact values: any supported Mac has at least 4 GiB and the binary
        // GiB conversion must stay consistent with the raw byte count.
        XCTAssertGreaterThanOrEqual(capability.physicalMemoryGigabytes, 4)
        XCTAssertEqual(
            capability.physicalMemoryGigabytes,
            Double(capability.physicalMemoryBytes) / 1_073_741_824,
            accuracy: 0.0001
        )
    }

    func test_current_reportsCompileTimeArchitecture() {
        let capability = HardwareCapabilityProbe.current()

        // The probe intentionally answers from compile-time architecture; the test target builds
        // for the same architecture, so the same condition is the ground truth here.
        #if arch(arm64)
        XCTAssertTrue(capability.isAppleSilicon)
        #else
        XCTAssertFalse(capability.isAppleSilicon)
        #endif
    }
}
