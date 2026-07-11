import Darwin
import Foundation

/// Reads process ancestry without launching helper tools or exposing command text.
///
/// Terminal TUI detection needs to know whether `claude` is running beneath the frontmost
/// terminal host. Keeping that low-level Darwin work here gives the detector a small, pure input
/// (`[String]`) and keeps process-table details out of the UI and focus models.
nonisolated enum ProcessTreeInspector {
    static func descendantProcessNames(of parentPid: Int32) -> [String] {
        subtreeProcessNames(rootedAt: [parentPid], includingRoots: false)
    }

    /// Roots are included because `exec claude` replaces a shell image without changing its PID.
    static func subtreeProcessNames(
        rootedAt rootPids: [Int32],
        includingRoots: Bool = true
    ) -> [String] {
        let table = processTable()
        guard !table.isEmpty else { return [] }

        var byPID: [Int32: kinfo_proc] = [:]
        var byParent: [Int32: [kinfo_proc]] = [:]
        for process in table {
            byPID[process.kp_proc.p_pid] = process
            byParent[process.kp_eproc.e_ppid, default: []].append(process)
        }

        var names: [String] = []
        if includingRoots {
            names.append(contentsOf: rootPids.compactMap { byPID[$0] }.map(processName))
        }

        var pending = rootPids
        var visited = Set(rootPids)
        while let pid = pending.popLast() {
            for child in byParent[pid] ?? [] where visited.insert(child.kp_proc.p_pid).inserted {
                pending.append(child.kp_proc.p_pid)
                let name = processName(child)
                if !name.isEmpty { names.append(name) }
            }
        }
        return names
    }

    private static func processName(_ process: kinfo_proc) -> String {
        withUnsafePointer(to: process.kp_proc.p_comm) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                String(cString: $0)
            }
        }
    }

    private static func processTable() -> [kinfo_proc] {
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var byteCount: size_t = 0
        let queryCount = u_int(query.count)
        guard sysctl(&query, queryCount, nil, &byteCount, nil, 0) == 0,
              byteCount > 0 else { return [] }

        // Process creation can race the size/read pair. A small amount of spare capacity avoids
        // treating that ordinary race as a negative Claude Code classification.
        let elementSize = MemoryLayout<kinfo_proc>.size
        var buffer = [kinfo_proc](
            repeating: kinfo_proc(),
            count: (byteCount / elementSize) + 16
        )
        byteCount = buffer.count * elementSize
        let result = buffer.withUnsafeMutableBufferPointer {
            sysctl(&query, queryCount, $0.baseAddress, &byteCount, nil, 0)
        }
        guard result == 0 else { return [] }
        return Array(buffer.prefix(byteCount / elementSize))
    }
}
