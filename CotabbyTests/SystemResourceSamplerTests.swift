import Foundation
import XCTest
@testable import Cotabby

/// Exercises the Mach-kernel sampling path in-process. Exact values are nondeterministic by
/// nature, so every assertion is a sanity bound: the point is that the unsafe-pointer Mach calls
/// produce live, plausible readings rather than zeroed or corrupted structs.
final class SystemResourceSamplerTests: XCTestCase {
    func test_sample_reportsPlausibleCPUPercent() {
        let sample = SystemResourceSampler.sample()

        XCTAssertTrue(sample.cpuPercent.isFinite)
        XCTAssertGreaterThanOrEqual(sample.cpuPercent, 0)
        // The total can exceed 100 on multi-core machines (that is the documented contract), but
        // it can never plausibly exceed every core running flat out with generous headroom.
        let upperBound = Double(ProcessInfo.processInfo.activeProcessorCount) * 100.0 * 4.0
        XCTAssertLessThan(sample.cpuPercent, upperBound)
    }

    func test_sample_reportsLiveProcessFootprint() {
        let sample = SystemResourceSampler.sample()

        // The hosted test process (the full Cotabby app) always occupies well over 10 MB, and a
        // footprint reading beyond several times installed RAM means the struct rebind went wrong.
        XCTAssertGreaterThan(sample.footprintBytes, 10_000_000)
        XCTAssertLessThan(sample.footprintBytes, ProcessInfo.processInfo.physicalMemory * 4)
    }

    func test_sample_staysStableAcrossConsecutiveReads() {
        let first = SystemResourceSampler.sample()
        let second = SystemResourceSampler.sample()

        // Adjacent footprint readings of the same idle-ish process must land in the same order of
        // magnitude; a 4x jump between back-to-back calls indicates a bogus read, not real growth.
        XCTAssertGreaterThan(second.footprintBytes, first.footprintBytes / 4)
        XCTAssertLessThan(second.footprintBytes, first.footprintBytes * 4)
        XCTAssertGreaterThanOrEqual(second.cpuPercent, 0)
    }

    func test_sampleValues_compareByBothFields() {
        // The sample's synthesized Equatable inherits the app module's default MainActor
        // isolation, so the comparisons run through the main-actor hop helper.
        runOnMainActor {
            let sample = SystemResourceSample(cpuPercent: 12.5, footprintBytes: 1_024)

            XCTAssertEqual(sample, SystemResourceSample(cpuPercent: 12.5, footprintBytes: 1_024))
            XCTAssertNotEqual(sample, SystemResourceSample(cpuPercent: 12.5, footprintBytes: 2_048))
            XCTAssertNotEqual(sample, SystemResourceSample(cpuPercent: 99.0, footprintBytes: 1_024))
        }
    }
}

private func runOnMainActor<Result>(
    _ body: @MainActor () throws -> Result
) rethrows -> Result {
    if Thread.isMainThread {
        return try MainActor.assumeIsolated(body)
    }

    return try DispatchQueue.main.sync {
        try MainActor.assumeIsolated(body)
    }
}
