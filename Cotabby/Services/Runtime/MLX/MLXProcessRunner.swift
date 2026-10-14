import Foundation

/// File overview:
/// Runs one MLX helper process (uv, tar, a Python one-liner) to completion off the main actor,
/// with a timeout, cooperative cancellation and bounded output capture. Owned by nobody: callers
/// await `run` and get a value back. Kept separate from the long-lived server process
/// (`MLXServerManager`), which never "completes".

nonisolated struct MLXProcessResult: Equatable, Sendable {
    let status: Int32
    let stdout: String
    let stderrTail: [String]
}

nonisolated enum MLXProcessRunnerError: LocalizedError, Equatable {
    case timedOut(tail: [String])
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .timedOut: return "The MLX helper took too long and was stopped."
        case .launchFailed(let message): return "The MLX helper could not start: \(message)"
        }
    }
}

/// Collects a child's output while it runs. Both pipes must be drained continuously: a child
/// that fills a 64 KB pipe buffer blocks forever. Stdout is kept whole up to 1 MiB (callers read
/// short answers from it); stderr keeps only its last lines for error messages.
nonisolated final class MLXOutputCollector: @unchecked Sendable {
    static let stdoutLimit = 1 << 20

    private let lock = NSLock()
    private let tailLines: Int
    private var stdout = Data()
    private var stderrLines: [String] = []
    /// Bytes after the last line break. Kept as bytes, not text, so a UTF-8 character split across
    /// two pipe reads is decoded whole once its line is complete.
    private var partialStderrLine = Data()
    /// Cap on an unterminated stderr fragment (keeps the last bytes).
    private static let partialLineLimit = 8 * 1024
    private var stdoutClosed = false
    private var stderrClosed = false

    init(tailLines: Int) {
        self.tailLines = tailLines
    }

    /// True once both pipes have reached EOF. The runner polls this during its bounded drain.
    var bothStreamsClosed: Bool {
        lock.withLock { stdoutClosed && stderrClosed }
    }

    func appendStdout(_ data: Data) {
        lock.withLock {
            let room = Self.stdoutLimit - stdout.count
            if room > 0 { stdout.append(data.prefix(room)) }
        }
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            // `\r` separates lines too: progress redraws (tqdm) overwrite one line with carriage
            // returns and would otherwise grow a single "line" without bound.
            partialStderrLine.append(data)
            var lineStart = partialStderrLine.startIndex
            for index in partialStderrLine.indices where Self.isLineBreak(partialStderrLine[index]) {
                let line = partialStderrLine[lineStart..<index]
                if !line.isEmpty { stderrLines.append(Self.text(line)) }
                lineStart = partialStderrLine.index(after: index)
            }
            partialStderrLine = Self.boundedFragment(partialStderrLine[lineStart...])
            if stderrLines.count > tailLines { stderrLines.removeFirst(stderrLines.count - tailLines) }
        }
    }

    private static func isLineBreak(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
    }

    /// The last `partialLineLimit` bytes of an unterminated fragment. A cut can land inside a
    /// multi-byte character, so leading UTF-8 continuation bytes (`10xxxxxx`) are dropped with it.
    private static func boundedFragment(_ fragment: Data) -> Data {
        guard fragment.count > partialLineLimit else { return Data(fragment) }
        var kept = fragment.suffix(partialLineLimit)
        while let first = kept.first, first & 0xC0 == 0x80 { kept = kept.dropFirst() }
        return Data(kept)
    }

    /// Decodes one line or answer. A child's output is almost always UTF-8; anything else is
    /// reported by size rather than shown as mojibake.
    static func text(_ bytes: Data) -> String {
        String(bytes: bytes, encoding: .utf8) ?? "<\(bytes.count) bytes of non-UTF-8 output>"
    }

    func markStdoutClosed() {
        lock.withLock { stdoutClosed = true }
    }

    func markStderrClosed() {
        lock.withLock { stderrClosed = true }
    }

    var stdoutText: String {
        lock.withLock { Self.text(stdout) }
    }

    var stderrTail: [String] {
        lock.withLock {
            let all = partialStderrLine.isEmpty ? stderrLines : stderrLines + [Self.text(partialStderrLine)]
            return Array(all.suffix(tailLines))
        }
    }
}

/// Bridges `Process.terminationHandler` (a background thread) to one awaiting task, in either
/// order: the process may exit before anyone awaits.
nonisolated private final class ExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func finish(_ value: Int32) {
        let waiting: CheckedContinuation<Int32, Never>? = lock.withLock {
            status = value
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let ready: Int32? = lock.withLock {
                if let status { return status }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

nonisolated enum MLXProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration,
        tailLines: Int = 20
    ) async throws -> MLXProcessResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let output = MLXOutputCollector(tailLines: tailLines)
        // At EOF the handler is called with empty data, and it keeps being called until it is removed.
        // Removing it at EOF and recording the close is how the drain below knows the pipe is done.
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                output.markStdoutClosed()
            } else {
                output.appendStdout(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                output.markStderrClosed()
            } else {
                output.appendStderr(data)
            }
        }
        let exit = ExitSignal()
        process.terminationHandler = { exit.finish($0.terminationStatus) }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw MLXProcessRunnerError.launchFailed(error.localizedDescription)
        }

        // Either the exit status or nil for "the timeout fired first". The group always waits
        // for the exit task, so every path below makes sure the child actually ends.
        let status: Int32?
        do {
            status = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Int32?.self) { group in
                    group.addTask { await exit.wait() }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        return nil
                    }
                    // `next()` is `Int32??`: nil when the group is empty, `.some(nil)` on timeout.
                    let first = try await group.next().flatMap { $0 }
                    if first == nil { Self.stop(process) }
                    group.cancelAll()
                    return first
                }
            } onCancel: {
                Self.stop(process)
            }
        } catch {
            await Self.drain(output, stdoutPipe, stderrPipe)
            throw error
        }

        await Self.drain(output, stdoutPipe, stderrPipe)

        try Task.checkCancellation()
        guard let status else {
            throw MLXProcessRunnerError.timedOut(tail: output.stderrTail)
        }
        return MLXProcessResult(status: status, stdout: output.stdoutText, stderrTail: output.stderrTail)
    }

    /// Waits a bounded grace (about 1 s) for both pipes to reach EOF, then detaches the handlers.
    /// The direct child may be gone while a grandchild (a `sleep &`, a uv build backend) still holds
    /// the write end open. A blocking read would then wait forever and could not be cancelled, so
    /// the drain polls the collector instead and abandons whatever has not arrived after the grace.
    /// A cancelled task skips the wait: its sleep would return at once and nothing is waiting on it.
    private static func drain(_ output: MLXOutputCollector, _ stdoutPipe: Pipe, _ stderrPipe: Pipe) async {
        for _ in 0..<20 {
            if output.bothStreamsClosed || Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }

    /// SIGTERM now, SIGKILL three seconds later if the child ignored it.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
