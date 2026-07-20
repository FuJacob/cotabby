import Foundation
import XCTest
@testable import Cotabby

/// Behavior of the rolling CPU/RAM window behind the Performance pane graphs: reference-counted
/// sampling, the immediate first reading, the 60-sample cap, identity reset, and the weak-timer
/// teardown contract. The store declares `nonisolated deinit`, so instances may deallocate freely
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

    private func makeStore(
        probe: SamplerProbe,
        sampleInterval: TimeInterval = 600
    ) -> SystemMetricsStore {
        // The default interval is deliberately huge so timer ticks can never interleave with
        // assertions; timer-driven tests override it explicitly.
        runOnMainActor {
            SystemMetricsStore(
                sampleInterval: sampleInterval,
                physicalMemoryBytes: 8_589_934_592,
                sampler: { probe.next() }
            )
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
