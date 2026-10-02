import Foundation
import IOKit

/// File overview:
/// Reads GPU usage from the IORegistry so the Performance pane can graph it next to CPU and memory.
/// macOS has no public per-process GPU API, but the GPU driver (the `IOAccelerator` service) publishes
/// two things any process may read without special permissions, the same sources Activity Monitor
/// uses:
///
/// - `PerformanceStatistics` on the accelerator: whole-Mac GPU utilization and GPU memory in use.
/// - `AppUsage` on each Metal client the driver opened for a process (a child of the accelerator
///   whose `IOUserClientCreator` reads "pid <n>, <name>"): that client's cumulative GPU time.
///
/// Cotabby's own GPU share is therefore the growth of its cumulative GPU time between two readings
/// divided by the wall time between them. Measured on Apple silicon, `accumulatedGPUTime` is in
/// nanoseconds: a llama.cpp prompt benchmark accumulated 1.84 s of it over 2.01 s of wall time while
/// the device reported 81-99% utilization.
///
/// Kept in `Support/` beside `SystemResourceSampler`: `SystemMetricsStore` owns the polling cadence,
/// this type only answers "what is true right now", and the parsing and arithmetic are pure static
/// functions so they can be tested without a GPU.

/// One reading of the GPU counters. Every field is optional because a Mac without an accelerator
/// service, or a driver that renames a key, should leave the graph empty rather than show zeros.
struct GPUStatisticsReading: Equatable {
    /// Whole-Mac GPU busy share, 0-100 ("Device Utilization %").
    let deviceUtilizationPercent: Double?
    /// GPU memory in use across the whole Mac, in bytes ("In use system memory"). On Apple silicon
    /// this is unified memory the GPU has wired, which includes a loaded model's weights.
    let inUseMemoryBytes: UInt64?
    /// This process's cumulative GPU time in nanoseconds, summed over its Metal clients. `nil` when
    /// the process has never opened the GPU.
    let processGPUTimeNanoseconds: UInt64?

    static let unavailable = GPUStatisticsReading(
        deviceUtilizationPercent: nil,
        inUseMemoryBytes: nil,
        processGPUTimeNanoseconds: nil
    )
}

nonisolated enum GPUStatisticsReader {
    /// Reads the accelerator statistics and `pid`'s GPU time. A few IORegistry property reads, cheap
    /// enough for the store's one-second timer on the main thread.
    static func read(pid: pid_t = getpid()) -> GPUStatisticsReading {
        var services: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &services
        ) == KERN_SUCCESS else {
            return .unavailable
        }
        // Every `io_object_t` handed out by IOKit carries a reference we own; releasing the
        // iterators and each entry keeps a once-per-second reader from leaking kernel objects.
        defer { IOObjectRelease(services) }

        var statistics: [String: Any]?
        var appUsages: [[[String: Any]]] = []
        while case let service = IOIteratorNext(services), service != 0 {
            defer { IOObjectRelease(service) }
            // A Mac with more than one GPU reports each; the first with statistics is the one in use.
            if statistics == nil {
                statistics = property("PerformanceStatistics", of: service) as? [String: Any]
            }
            appUsages += appUsageOfClients(of: service, pid: pid)
        }
        return GPUStatisticsReading(
            deviceUtilizationPercent: deviceUtilizationPercent(from: statistics),
            inUseMemoryBytes: inUseMemoryBytes(from: statistics),
            processGPUTimeNanoseconds: accumulatedGPUTime(fromClients: appUsages)
        )
    }

    // MARK: - Pure parsing and arithmetic

    static func deviceUtilizationPercent(from statistics: [String: Any]?) -> Double? {
        (statistics?["Device Utilization %"] as? NSNumber).map { min(max($0.doubleValue, 0), 100) }
    }

    static func inUseMemoryBytes(from statistics: [String: Any]?) -> UInt64? {
        (statistics?["In use system memory"] as? NSNumber)?.uint64Value
    }

    /// Total GPU time across a process's clients, each holding one `AppUsage` entry per API it used.
    /// `nil` when the process has no client at all, so a process that never touched the GPU reads as
    /// "no data" rather than as an idle 0%.
    static func accumulatedGPUTime(fromClients clients: [[[String: Any]]]) -> UInt64? {
        guard !clients.isEmpty else { return nil }
        return clients.joined().reduce(UInt64(0)) { total, usage in
            total &+ ((usage["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0)
        }
    }

    /// The process's GPU share between two readings, 0-100. `nil` when either reading has no GPU
    /// time, no time passed, or the counter went backwards (a client closed when the model was
    /// unloaded or reloaded drops its accumulated time).
    static func processUtilizationPercent(
        previousNanoseconds: UInt64?,
        currentNanoseconds: UInt64?,
        elapsedSeconds: TimeInterval
    ) -> Double? {
        guard let previousNanoseconds, let currentNanoseconds,
              currentNanoseconds >= previousNanoseconds, elapsedSeconds > 0
        else { return nil }
        let busySeconds = Double(currentNanoseconds - previousNanoseconds) / 1_000_000_000
        return min(busySeconds / elapsedSeconds * 100, 100)
    }

    // MARK: - IORegistry access

    /// `AppUsage` arrays of the accelerator's clients that `pid` created.
    private static func appUsageOfClients(of service: io_object_t, pid: pid_t) -> [[[String: Any]]] {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(children) }

        let creatorPrefix = "pid \(pid),"
        var usages: [[[String: Any]]] = []
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            guard let creator = property("IOUserClientCreator", of: child) as? String,
                  creator.hasPrefix(creatorPrefix)
            else { continue }
            usages.append(property("AppUsage", of: child) as? [[String: Any]] ?? [])
        }
        return usages
    }

    /// A registry property bridged to Foundation. `IORegistryEntryCreateCFProperty` follows the
    /// Create rule, so the value is taken retained and released by ARC once bridged.
    private static func property(_ key: String, of entry: io_object_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }
}
