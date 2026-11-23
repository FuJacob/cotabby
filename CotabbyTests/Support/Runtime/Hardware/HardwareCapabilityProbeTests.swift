import XCTest
@testable import Cotabby

/// The probe is the seam between real host hardware and the pure
/// `OnboardingTemplateRecommender`. Its values come from the machine running the tests, so the
/// only thing worth asserting is that the reading is live rather than zeroed.
final class HardwareCapabilityProbeTests: XCTestCase {
    func test_current_reportsPlausibleInstalledMemory() {
        let capability = HardwareCapabilityProbe.current()

        // Any Mac that can run Cotabby has at least 4 GiB.
        XCTAssertGreaterThanOrEqual(capability.physicalMemoryGigabytes, 4)
    }
}
