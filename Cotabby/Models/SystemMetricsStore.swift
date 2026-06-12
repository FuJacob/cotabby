import Combine
import Foundation

/// File overview:
/// A rolling, in-memory window of the app's own CPU and memory readings, published for the
/// Performance pane's live graphs. Unlike `PerformanceMetricsStore` this is deliberately *not*
/// persisted: the samples are only meaningful while you are watching them, and polling stops the
/// moment the pane goes away. Sampling is reference-counted via `beginSampling`/`endSampling` so a
/// single shared store can back any number of views without leaking a timer when one disappears.

/// One CPU+RAM reading on the rolling timeline. `id` is a monotonic counter rather than the
/// timestamp so SwiftUI Charts has a stable identity even if two samples land in the same instant.
struct SystemMetricSample: Identifiable, Equatable {
    let id: UInt64
    let timestamp: Date
    let cpuPercent: Double
    let footprintBytes: UInt64
}

@MainActor
final class SystemMetricsStore: ObservableObject {
    /// Number of samples retained. At the default one-second cadence this is a rolling 60-second
    /// window, which is enough to watch a generation spike rise and fall without unbounded growth.
    static let maximumSamples = 60
    nonisolated static let defaultInterval: TimeInterval = 1.0

    @Published private(set) var samples: [SystemMetricSample] = []

    /// Total installed RAM, captured once. The RAM graph uses it only as an upper bound for context;
    /// the visible axis auto-scales to the recent peak so small footprints stay legible.
    let physicalMemoryBytes: UInt64

    private let sampleInterval: TimeInterval
    private let sampler: () -> SystemResourceSample
    private var timer: Timer?
    private var nextSampleID: UInt64 = 0
    /// How many live views currently want sampling. Polling runs only while this is positive.
    private var activeRequests = 0

    init(
        sampleInterval: TimeInterval = SystemMetricsStore.defaultInterval,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        sampler: @escaping () -> SystemResourceSample = { SystemResourceSampler.sample() }
    ) {
        self.sampleInterval = sampleInterval
        self.physicalMemoryBytes = physicalMemoryBytes
        self.sampler = sampler
    }

    nonisolated deinit {
        // This store is `@MainActor` with stored properties, so a `nonisolated deinit` avoids the
        // macOS 14 isolated-deinit double-free. It deliberately does no cleanup: it cannot touch the
        // MainActor-isolated `timer`, and it does not need to. `RunLoop.main` retains a scheduled
        // repeating timer, so it would otherwise outlive the store, but the timer captures `self`
        // weakly and invalidates itself on its first tick after the store is gone (see `startTimer`).
    }

    /// Register interest in live sampling. The first caller starts the timer and takes an immediate
    /// reading so the graph shows a point right away instead of waiting a full interval.
    func beginSampling() {
        activeRequests += 1
        guard timer == nil else { return }
        captureSample()
        startTimer()
    }

    /// Balance a prior `beginSampling`. Sampling pauses (and the timer is released) once the last
    /// interested view goes away, so a backgrounded Settings window costs nothing.
    func endSampling() {
        activeRequests = max(0, activeRequests - 1)
        guard activeRequests == 0 else { return }
        stopTimer()
        // The rolling window is only meaningful while you are watching it, so drop it when the last
        // viewer leaves. Otherwise re-opening the pane would stitch fresh points onto a stale cluster
        // separated by a visible time gap (the chart plots by wall-clock `Date`), looking broken.
        clear()
    }

    /// Drop the rolling window and reset sample identity. Resetting `nextSampleID` keeps a later
    /// sampling session starting from a clean, contiguous timeline rather than continuing the old one.
    func clear() {
        samples = []
        nextSampleID = 0
    }

    private func startTimer() {
        // `.common` mode keeps the timer firing while the user scrolls or drags the Settings window;
        // the default mode would stall the graph during exactly the interactions a debugger uses.
        let timer = Timer(timeInterval: sampleInterval, repeats: true) { [weak self] firedTimer in
            // `RunLoop.main` retains a scheduled repeating timer and the `nonisolated deinit` cannot
            // invalidate it, so the timer tears itself down on the first tick after the store is gone.
            // This bounds any leak to a single interval instead of firing forever past `deinit`.
            guard let self else {
                firedTimer.invalidate()
                return
            }
            // The main run loop fires this on the main thread, which is the MainActor's executor, so
            // assuming isolation here is sound and avoids a Task hop per tick.
            MainActor.assumeIsolated {
                self.captureSample()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func captureSample() {
        let reading = sampler()
        let sample = SystemMetricSample(
            id: nextSampleID,
            timestamp: Date(),
            cpuPercent: reading.cpuPercent,
            footprintBytes: reading.footprintBytes
        )
        nextSampleID &+= 1
        var updated = samples
        updated.append(sample)
        if updated.count > Self.maximumSamples {
            updated.removeFirst(updated.count - Self.maximumSamples)
        }
        samples = updated
    }
}
