import Darwin
import Foundation

/// File overview:
/// Reads this process's instantaneous CPU and memory usage straight from the Mach kernel so the
/// Performance pane can graph the app's own footprint while debugging. Kept as a pure, dependency-
/// free helper in `Support/` because the only tricky parts are Mach struct layout and the manual
/// memory management `task_threads` forces on us. `SystemMetricsStore` owns the polling cadence;
/// this type only answers "what is true right now".

/// A single point-in-time reading of the current process's resource usage.
struct SystemResourceSample: Equatable {
    /// Total CPU usage across all live threads, in percent. Can exceed 100 on a multi-core machine
    /// (e.g. 230 means roughly 2.3 cores busy), which is exactly what we want to see when llama.cpp
    /// generation saturates the performance cores.
    let cpuPercent: Double

    /// Physical memory footprint in bytes. `phys_footprint` is the same figure Activity Monitor and
    /// Xcode's memory gauge report, so the graph matches what a debugging contributor sees there.
    let footprintBytes: UInt64

    /// True when the numbers above also count a helper process Cotabby runs (the MLX server), so
    /// the Performance pane can say so instead of making Cotabby look like it alone uses that much.
    /// Set by the caller that chose to include the helper, not by the sampler itself.
    var includesMLXServer = false
}

nonisolated enum SystemResourceSampler {
    /// `extraProcessIDs` are child processes whose CPU and memory are added to the totals (the MLX
    /// server does the model work that llama.cpp does inside this process, so leaving it out would
    /// make an MLX user's graph read near zero). A pid that no longer exists contributes nothing.
    ///
    /// `baseline` holds the per-pid CPU readings the next call measures against. The default is one
    /// shared cache; a second periodic caller (the menu bar monitor) passes its own instance, because
    /// two callers sharing one cache would each reset the other's baseline and read CPU over a
    /// shortened, wrong window.
    static func sample(
        extraProcessIDs: [Int32] = [],
        baseline previousCPUTime: PreviousCPUReadings = sharedBaseline
    ) -> SystemResourceSample {
        var cpu = currentCPUPercent()
        var footprint = currentMemoryFootprint()
        let now = Date()
        var seen = Set<Int32>()
        for pid in extraProcessIDs {
            guard let usage = processUsage(pid: pid) else { continue }
            seen.insert(pid)
            footprint += usage.footprintBytes
            if let previous = previousCPUTime.withLock({ $0[pid] }) {
                cpu += cpuPercent(
                    previousTicks: previous.ticks, currentTicks: usage.cpuTicks,
                    elapsedSeconds: now.timeIntervalSince(previous.date), timebase: machTimebase)
            }
            previousCPUTime.withLock { $0[pid] = (usage.cpuTicks, now) }
        }
        // Forget processes that are gone or no longer asked about, so a reused pid cannot be
        // measured against a stranger's old reading.
        previousCPUTime.withLock { cache in cache = cache.filter { seen.contains($0.key) } }
        return SystemResourceSample(cpuPercent: cpu, footprintBytes: footprint)
    }

    /// CPU use of one process between two readings, in percent of one core (so it can exceed 100).
    /// `ri_user_time + ri_system_time` are Mach absolute-time ticks, which on Apple Silicon are not
    /// nanoseconds, so they are scaled by the timebase first. Pure so the conversion is testable.
    static func cpuPercent(
        previousTicks: UInt64, currentTicks: UInt64, elapsedSeconds: TimeInterval,
        timebase: (numer: UInt32, denom: UInt32)
    ) -> Double {
        guard elapsedSeconds > 0, currentTicks >= previousTicks, timebase.denom > 0 else { return 0 }
        let deltaNanoseconds = Double(currentTicks - previousTicks) * Double(timebase.numer) / Double(timebase.denom)
        return deltaNanoseconds / (elapsedSeconds * 1_000_000_000) * 100
    }

    /// Default CPU baseline, used by the Performance pane's store. The lock keeps it valid if two
    /// threads sample at once; separate callers should still use separate instances.
    static let sharedBaseline = PreviousCPUReadings()

    private static let machTimebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (info.numer, info.denom)
    }()

    private static func processUsage(pid: Int32) -> (footprintBytes: UInt64, cpuTicks: UInt64)? {
        var info = rusage_info_v4()
        // `proc_pid_rusage` fills a caller-provided struct through an untyped `rusage_info_t`
        // pointer; the rebind hands it our typed storage. Failure (no such process, not ours to
        // inspect) returns nonzero and we report nothing for that pid.
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return nil }
        return (info.ri_phys_footprint, info.ri_user_time + info.ri_system_time)
    }

    private static func currentMemoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        // `task_info` writes into a C struct; rebind the typed pointer to the `integer_t` array the
        // Mach ABI expects. The capacity must match the count we pass or the kernel can overrun.
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }

    private static func currentCPUPercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threadList else {
            return 0
        }
        // `task_threads` allocates the thread array in our own address space and hands us ownership;
        // failing to `vm_deallocate` it leaks a page on every single sample (once per second while
        // the pane is open), so the defer is load-bearing, not hygiene.
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threadList)),
                vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            )
        }

        var total: Double = 0
        let basicInfoCount = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info_data_t()
            var count = basicInfoCount
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                    thread_info(threadList[index], thread_flavor_t(THREAD_BASIC_INFO), rebound, &count)
                }
            }
            guard result == KERN_SUCCESS else { continue }
            // Idle threads report a stale `cpu_usage` from when they last ran; counting them would
            // pin the graph near 100% even when the app is asleep. Skip them.
            if info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return total
    }
}

/// A tiny lock-protected dictionary of the previous per-pid CPU readings. A class because a static
/// needs reference storage that two callers can share; it owns nothing else.
nonisolated final class PreviousCPUReadings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int32: (ticks: UInt64, date: Date)] = [:]

    func withLock<T>(_ body: (inout [Int32: (ticks: UInt64, date: Date)]) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}
