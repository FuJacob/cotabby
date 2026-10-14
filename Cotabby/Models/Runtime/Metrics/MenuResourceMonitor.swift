import Combine
import Foundation

/// File overview:
/// Publishes `ResourceUsageSummary` for the menu bar popover. Unlike `SystemMetricsStore` it keeps
/// no history: it holds only the latest value and polls only between `start()` and `stop()`, which
/// the popover calls when its window is presented or dismissed (and from `.onAppear` /
/// `.onDisappear` as a fallback), so a closed menu costs nothing. One instance
/// lives for the app's lifetime (built by `CotabbyAppEnvironment`).
@MainActor
final class MenuResourceMonitor: ObservableObject {
    nonisolated static let defaultInterval: TimeInterval = 2.0

    @Published private(set) var summary: ResourceUsageSummary?

    private let interval: TimeInterval
    private let sample: () -> ResourceUsageSummary
    private let onStop: () -> Void
    private let primingDelay: TimeInterval
    private var timer: Timer?
    private var isActive = false

    init(
        interval: TimeInterval = MenuResourceMonitor.defaultInterval,
        sample: @escaping () -> ResourceUsageSummary,
        primingDelay: TimeInterval = 0.3,
        onStop: @escaping () -> Void = {}
    ) {
        self.primingDelay = primingDelay
        self.interval = interval
        self.sample = sample
        self.onStop = onStop
    }

    nonisolated deinit {
        // Same reasoning as `SystemMetricsStore`: no cleanup from a nonisolated deinit; the timer
        // holds `self` weakly and invalidates itself on its first tick after we are gone.
    }

    /// Seeds the CPU/GPU baselines with an unpublished reading, then publishes the first real one
    /// after `primingDelay` and every `interval` after that. Publishing the priming reading itself
    /// would show RAM (and "incl. MLX") without CPU or GPU deltas, which need two readings.
    /// Idempotent: a second call while active does nothing.
    func start() {
        guard !isActive else { return }
        isActive = true
        _ = sample()
        let first = Timer(timeInterval: primingDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.isActive else { return }
                self.tick()
                self.startRepeating()
            }
        }
        RunLoop.main.add(first, forMode: .common)
        timer = first
    }

    private func startRepeating() {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] fired in
            guard let self else {
                fired.invalidate()
                return
            }
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Idempotent: only the first call after `start()` clears state and notifies.
    func stop() {
        guard isActive else { return }
        isActive = false
        timer?.invalidate()
        timer = nil
        summary = nil
        onStop()
    }

    /// One reading. Internal so tests can drive it without waiting for a real timer.
    func tick() {
        summary = sample()
    }

    var isRunning: Bool { isActive }
}
