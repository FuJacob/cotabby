import Foundation
import XCTest
@testable import Cotabby

/// Behavior of the rolling CPU/RAM/GPU window behind the Performance pane graphs: reference-counted
/// sampling, the immediate first reading, the 60-sample cap, identity reset, the GPU share baseline,
/// and the weak-timer teardown contract. The store declares `nonisolated deinit`, so instances may deallocate freely
/// inside the app-hosted runner; main-actor work still runs through `runOnMainActor` because the
/// test class itself must not be `@MainActor`.
final class SystemMetricsStoreTests: XCTestCase {
    /// Deterministic sampler stand-in: each reading is derived from a call counter so tests can
    /// tell exactly which capture produced which sample.
    private final class SamplerProbe {
        private(set) var sampleCount = 0

        func next() -> SystemResourceSample {
            sampleCount += 1
            return SystemResourceSample(
                cpuPercent: Double(sampleCount),
                footprintBytes: UInt64(sampleCount) * 100
            )
        }
    }

    /// Scripted GPU counters plus a fake monotonic clock. Each capture reads the next scripted GPU
    /// time (repeating the last once the script runs out) and advances the clock by `step`, so the
    /// store's GPU share is exact no matter how late the real timer fires.
    private final class GPUProbe {
        private let nanoseconds: [UInt64?]
        private let step: TimeInterval
        private var readCount = 0
        private var clock: TimeInterval = 1_000

        init(nanoseconds: [UInt64?], step: TimeInterval = 2) {
            self.nanoseconds = nanoseconds
            self.step = step
        }

        func read() -> GPUStatisticsReading {
            let value = nanoseconds[min(readCount, nanoseconds.count - 1)]
            readCount += 1
            return GPUStatisticsReading(
                deviceUtilizationPercent: 42,
                inUseMemoryBytes: 1_024,
                processGPUTimeNanoseconds: value
            )
        }

        func uptime() -> TimeInterval {
            clock += step
            return clock
        }
    }

    private func makeStore(
        probe: SamplerProbe,
        sampleInterval: TimeInterval = 600,
        gpu: GPUProbe? = nil
    ) -> SystemMetricsStore {
        // The default interval is deliberately huge so timer ticks can never interleave with
        // assertions; timer-driven tests override it explicitly.
        runOnMainActor {
            SystemMetricsStore(
                sampleInterval: sampleInterval,
                physicalMemoryBytes: 8_589_934_592,
                sampler: { probe.next() },
                gpuSampler: { gpu?.read() ?? .unavailable },
                uptime: { gpu?.uptime() ?? 0 }
            )
        }
    }

    /// Starts sampling on a fast timer and returns the first `count` samples' GPU shares.
    private func gpuShares(count: Int, from gpu: GPUProbe) -> [Double?] {
        let store = makeStore(probe: SamplerProbe(), sampleInterval: 0.01, gpu: gpu)
        runOnMainActor { store.beginSampling() }
        let reached = pumpRunLoop(timeout: 10) { runOnMainActor { store.samples.count >= count } }
        XCTAssertTrue(reached, "Timer never delivered \(count) samples")
        return runOnMainActor {
            defer { store.endSampling() }
            return store.samples.prefix(count).map(\.gpuPercent)
        }
    }

    /// Pumps the main run loop until `condition` holds or `timeout` elapses. Returns whether the
    /// condition was met, so callers fail with a real assertion instead of a hang.
    private func pumpRunLoop(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() {
            if Date() >= deadline {
                return false
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return true
    }

    // MARK: - GPU

    func test_gpuShare_isGPUTimeOverMonotonicTimeFromTheSecondSample() {
        // 0.5 s of GPU time per 2 s step of the injected clock is a 25% share.
        let gpu = GPUProbe(nanoseconds: [1_000_000_000, 1_500_000_000, 2_000_000_000])

        let shares = gpuShares(count: 3, from: gpu)

        XCTAssertEqual(shares, [nil, 25, 25], "The first reading has nothing to measure from")
    }

    func test_gpuShare_isMissingAcrossACounterResetAndThenResumes() {
        // A released command queue takes its time with it, so the total can shrink between samples.
        let gpu = GPUProbe(nanoseconds: [1_000_000_000, 2_000_000_000, 500_000_000, 1_500_000_000])

        let shares = gpuShares(count: 4, from: gpu)

        XCTAssertEqual(
            shares,
            [nil, 50, nil, 50],
            "A reset is unknown, not negative usage, and the next sample measures from it"
        )
    }

    func test_gpuShare_isMissingWhenACounterIsUnavailable() {
        let gpu = GPUProbe(nanoseconds: [1_000_000_000, nil, 2_000_000_000, 3_000_000_000])

        let shares = gpuShares(count: 4, from: gpu)

        XCTAssertEqual(shares, [nil, nil, nil, 50], "Both sides of a share need a counter")
    }

    func test_gpuDeviceFigures_areCarriedOnEverySample() {
        let probe = SamplerProbe()
        let store = makeStore(probe: probe, gpu: GPUProbe(nanoseconds: [0]))

        runOnMainActor {
            store.beginSampling()
            XCTAssertEqual(store.samples.first?.deviceGPUPercent, 42)
            XCTAssertEqual(store.samples.first?.gpuMemoryBytes, 1_024)
            store.endSampling()
        }
    }

    func test_gpuBaseline_doesNotCarryIntoTheNextSession() {
        let probe = SamplerProbe()
        let store = makeStore(probe: probe, gpu: GPUProbe(nanoseconds: [1_000_000_000, 2_000_000_000]))

        runOnMainActor {
            store.beginSampling()
            store.endSampling()

            store.beginSampling()
            // Measuring from the last session's reading would average over the time the pane was
            // closed. The new session starts without a share, just like the first one did.
            XCTAssertEqual(store.samples.count, 1)
            XCTAssertNil(store.samples.first?.gpuPercent)
            store.endSampling()
        }
    }

    func test_unavailableGPU_leavesEveryGPUFieldEmpty() {
        let store = makeStore(probe: SamplerProbe())

        runOnMainActor {
            store.beginSampling()
            let sample = store.samples.first
            XCTAssertNil(sample?.gpuPercent)
            XCTAssertNil(sample?.deviceGPUPercent)
            XCTAssertNil(sample?.gpuMemoryBytes)
            store.endSampling()
        }
    }

    // MARK: - Lifecycle and reference counting

    func test_init_startsEmptyAndKeepsInjectedPhysicalMemory() {
        let store = makeStore(probe: SamplerProbe())

        runOnMainActor {
            XCTAssertTrue(store.samples.isEmpty)
            XCTAssertEqual(store.physicalMemoryBytes, 8_589_934_592)
        }
    }

    func test_beginSampling_capturesAnImmediateFirstReading() {
        let probe = SamplerProbe()
        let store = makeStore(probe: probe)

        runOnMainActor {
            store.beginSampling()

            XCTAssertEqual(probe.sampleCount, 1, "First viewer should sample immediately, not wait an interval")
            XCTAssertEqual(store.samples.count, 1)
            XCTAssertEqual(store.samples.first?.id, 0)
            XCTAssertEqual(store.samples.first?.cpuPercent, 1.0)
            XCTAssertEqual(store.samples.first?.footprintBytes, 100)

            store.endSampling()
        }
    }

    func test_secondViewer_sharesTheRunningSession() {
        let probe = SamplerProbe()
        let store = makeStore(probe: probe)

        runOnMainActor {
            store.beginSampling()
            store.beginSampling()

            // The second viewer must not trigger a duplicate capture or a second timer.
            XCTAssertEqual(probe.sampleCount, 1)
            XCTAssertEqual(store.samples.count, 1)

            store.endSampling()
            XCTAssertEqual(store.samples.count, 1, "Window survives while one viewer remains")

            store.endSampling()
            XCTAssertTrue(store.samples.isEmpty, "Last viewer leaving drops the stale window")
        }
    }

    func test_unbalancedEndSampling_clampsAndStaysUsable() {
        let probe = SamplerProbe()
        let store = makeStore(probe: probe)

        runOnMainActor {
            store.endSampling()
            XCTAssertTrue(store.samples.isEmpty)

            // A later begin/end pair must behave exactly like a fresh session: the unbalanced
            // call cannot leave the viewer count negative.
            store.beginSampling()
            XCTAssertEqual(store.samples.count, 1)
            store.endSampling()
            XCTAssertTrue(store.samples.isEmpty)
        }
    }

    func test_endSampling_resetsSampleIdentityForTheNextSession() {
        let probe = SamplerProbe()
        let store = makeStore(probe: probe)

        runOnMainActor {
            store.beginSampling()
            XCTAssertEqual(store.samples.last?.id, 0)
            store.endSampling()

            store.beginSampling()
            // A fresh session restarts the monotonic ID at zero instead of continuing the old
            // timeline, which is what keeps SwiftUI Charts from stitching sessions together.
            XCTAssertEqual(store.samples.last?.id, 0)
            store.endSampling()
        }
    }

    func test_clear_dropsTheWindowWithoutStoppingSampling() {
        let probe = SamplerProbe()
        let store = makeStore(probe: probe)

        runOnMainActor {
            store.beginSampling()
            XCTAssertEqual(store.samples.count, 1)

            store.clear()
            XCTAssertTrue(store.samples.isEmpty)

            store.endSampling()
        }
    }

    // MARK: - Timer-driven capture

    func test_timer_appendsContiguousSamplesWhileActive() {
        let probe = SamplerProbe()
        let store = makeStore(probe: probe, sampleInterval: 0.01)

        runOnMainActor { store.beginSampling() }
        let reachedThree = pumpRunLoop(timeout: 10) {
            runOnMainActor { store.samples.count >= 3 }
        }

        XCTAssertTrue(reachedThree, "Timer never delivered follow-up samples")
        runOnMainActor {
            let ids = store.samples.map(\.id)
            XCTAssertEqual(ids, Array(0..<UInt64(ids.count)), "Sample IDs must be contiguous from zero")
            XCTAssertEqual(store.samples.first?.cpuPercent, 1.0, "First sample is the immediate capture")
            store.endSampling()
        }
    }

    func test_rollingWindow_capsAtMaximumSamplesDroppingOldest() {
        let probe = SamplerProbe()
        let store = makeStore(probe: probe, sampleInterval: 0.002)

        runOnMainActor { store.beginSampling() }
        let target = runOnMainActor { UInt64(SystemMetricsStore.maximumSamples) + 5 }
        let overflowed = pumpRunLoop(timeout: 15) {
            runOnMainActor { (store.samples.last?.id ?? 0) >= target }
        }

        XCTAssertTrue(overflowed, "Timer never produced enough samples to overflow the window")
        // No further timer fires can land between the pump returning and these reads: the run
        // loop is only pumped inside `pumpRunLoop`, so the window below is stable.
        runOnMainActor {
            let samples = store.samples
            XCTAssertEqual(samples.count, SystemMetricsStore.maximumSamples)
            if let first = samples.first, let last = samples.last {
                XCTAssertEqual(first.id, last.id - UInt64(SystemMetricsStore.maximumSamples - 1))
            }
            XCTAssertEqual(
                samples.map(\.id),
                samples.map(\.id).sorted(),
                "Window must stay in capture order after dropping the oldest entries"
            )
            store.endSampling()
        }
    }

    func test_orphanedTimer_selfInvalidatesAfterStoreIsReleased() {
        let probe = SamplerProbe()
        weak var weakStore: SystemMetricsStore?

        // The pool drains any autoreleased references before the deallocation assertion below.
        autoreleasepool {
            runOnMainActor {
                let store = SystemMetricsStore(
                    sampleInterval: 0.01,
                    physicalMemoryBytes: 1_024,
                    sampler: { probe.next() }
                )
                store.beginSampling()
                weakStore = store
            }
        }

        // The timer captures the store weakly, so nothing should keep it alive after scope exit.
        XCTAssertNil(weakStore, "Scheduled timer must not retain the store")

        // Let the orphaned timer fire once: it must invalidate itself without crashing. The pump
        // is bounded and asserts nothing time-sensitive; it only gives the teardown path a chance
        // to run under the test's watch.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    // MARK: - Default configuration

    func test_defaultConfiguration_usesRealSamplerAndHostMemory() {
        runOnMainActor {
            let store = SystemMetricsStore()

            XCTAssertEqual(store.physicalMemoryBytes, ProcessInfo.processInfo.physicalMemory)

            store.beginSampling()
            XCTAssertEqual(store.samples.count, 1)
            // The default sampler is the real Mach-backed one, so the reading must be live.
            XCTAssertGreaterThan(store.samples.first?.footprintBytes ?? 0, 0)
            store.endSampling()
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
