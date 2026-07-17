import XCTest
@testable import Cotabby

/// The probe is the seam between real host hardware and the pure
/// `OnboardingTemplateRecommender`, so these tests pin its memory output to the authoritative
/// source it must mirror.
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

}
