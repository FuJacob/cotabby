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
///   whose `IOUserClientCreator` reads "pid <n>, <name>"). A process gets one client per Metal
///   device, and the client's `AppUsage` holds one entry per live command queue with that queue's
///   cumulative GPU time. An empty array is a client that has not submitted any work yet.
///
/// Cotabby's own GPU share is therefore the growth of its cumulative GPU time between two readings
/// divided by the time between them. Measured on Apple silicon, `accumulatedGPUTime` is in
/// nanoseconds: a llama.cpp prompt benchmark accumulated 1.84 s of it over 2.01 s of wall time while
/// the device reported 81-99% utilization. Releasing a command queue removes its entry and its time
/// with it (measured with a throwaway queue), so the total can shrink, for example when unloading the
/// model releases llama.cpp's queue.
///
/// Only work Cotabby submits itself is counted. Apple Intelligence generates in a separate system
/// process (a probe saw no GPU client of its own during generation), and an endpoint server such as
/// Ollama is its own process too, so their work never shows up in Cotabby's share.
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
    /// the process has never opened the GPU or one of its clients has no readable counter.
    let processGPUTimeNanoseconds: UInt64?

    static let unavailable = GPUStatisticsReading(
        deviceUtilizationPercent: nil,
        inUseMemoryBytes: nil,
        processGPUTimeNanoseconds: nil
    )
}

nonisolated enum GPUStatisticsReader {
    /// Reads the accelerator statistics and `pid`'s GPU time. Finding `pid`'s clients takes one
    /// property read per GPU client on the Mac (68 clients took about 0.5 ms on an M3 Pro), cheap
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
        var appUsages: [[[String: Any]]?] = []
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

    /// Total GPU time across a process's clients, each holding one `AppUsage` entry per command
    /// queue (`nil` for a client without a readable `AppUsage` array). `nil` when the process has no
    /// client at all, so a process that never touched the GPU reads as "no data" rather than as an
    /// idle 0%. Also `nil` when any client or entry lacks a usable counter: summing only the
    /// readable part would undercount, and a driver that stops publishing the counter would read as
    /// an idle GPU. An empty `AppUsage` array is real data, a client with no work submitted yet.
    static func accumulatedGPUTime(fromClients clients: [[[String: Any]]?]) -> UInt64? {
        guard !clients.isEmpty else { return nil }
        var total: UInt64 = 0
        for usages in clients {
            guard let usages else { return nil }
            for usage in usages {
                guard let nanoseconds = (usage["accumulatedGPUTime"] as? NSNumber)?.uint64Value else {
                    return nil
                }
                total &+= nanoseconds
            }
        }
        return total
    }

    /// The process's GPU share between two readings, 0-100. `nil` when either reading has no GPU
    /// time, no time passed, or the counter went backwards (a released command queue takes its
    /// accumulated time with it, so a model unload or reload can shrink the total).
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

    /// `AppUsage` arrays of the accelerator's clients that `pid` created, one element per client.
    /// A client whose `AppUsage` is missing or not an array of dictionaries contributes `nil`.
    private static func appUsageOfClients(of service: io_object_t, pid: pid_t) -> [[[String: Any]]?] {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(children) }

        let creatorPrefix = "pid \(pid),"
        var usages: [[[String: Any]]?] = []
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            // The trailing comma keeps pid 12 from matching pid 123's clients.
            guard let creator = property("IOUserClientCreator", of: child) as? String,
                  creator.hasPrefix(creatorPrefix)
            else { continue }
            usages.append(property("AppUsage", of: child) as? [[String: Any]])
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
