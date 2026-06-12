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
}

nonisolated enum SystemResourceSampler {
    static func sample() -> SystemResourceSample {
        SystemResourceSample(
            cpuPercent: currentCPUPercent(),
            footprintBytes: currentMemoryFootprint()
        )
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
