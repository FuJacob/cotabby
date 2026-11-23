import Foundation

nonisolated enum Aria2DownloadError: LocalizedError, Equatable {
    case invalidFilename
    case processFailed(exitCode: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidFilename:
            return "The model filename is not valid."
        case .processFailed(let code, let message):
            return "aria2c download failed (exit code \(code)): \(message)"
        }
    }
}

/// Owns one aria2c subprocess and translates its output and termination into app-level progress.
/// `ModelDownloadManager` creates a fresh instance for each active model download. A pause or
/// cancel the user requested surfaces as `DownloadInterruption`, never as `Aria2DownloadError`.
nonisolated final class Aria2DownloadService: @unchecked Sendable {
    private let progressHandler: @Sendable (Aria2Progress) -> Void
    private let processState = Aria2ProcessState()

    init(progressHandler: @escaping @Sendable (Aria2Progress) -> Void) {
        self.progressHandler = progressHandler
    }

    /// Downloads into a model-specific staging directory and returns the completed file URL.
    func download(
        from url: URL,
        filename: String,
        stagingDirectory: URL,
        executableURL: URL
    ) async throws -> URL {
        let outputFilename = (filename as NSString).lastPathComponent
        guard !outputFilename.isEmpty,
              outputFilename != ".",
              outputFilename != "..",
              !outputFilename.contains("/") else {
            throw Aria2DownloadError.invalidFilename
        }

        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        let targetURL = stagingDirectory.appendingPathComponent(outputFilename, isDirectory: false)
        let process = Self.makeProcess(
            executableURL: executableURL,
            sourceURL: url,
            filename: outputFilename,
            stagingDirectory: stagingDirectory
        )

        return try await withTaskCancellationHandler {
            try await waitForProcess(process, targetURL: targetURL)
        } onCancel: {
            processState.cancel()
        }
    }

    /// SIGINT asks aria2c to flush its `.aria2` control file before terminating.
    func pause() {
        processState.pause()
    }

    func cancel() {
        processState.cancel()
    }

    private func waitForProcess(_ process: Process, targetURL: URL) async throws -> URL {
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputBuffer = LockedTextBuffer()
        let errorBuffer = LockedTextBuffer()

        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Shared by the readability handlers and the termination drain below, so bytes that arrive
        // either way are parsed identically.
        let consumeOutput: @Sendable (Data) -> Void = { [progressHandler] data in
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                return
            }

            for line in outputBuffer.appendAndTakeCompleteLines(text) {
                if let progress = Aria2OutputParser.parse(line: line) {
                    progressHandler(progress)
                }
            }
        }
        let consumeError: @Sendable (Data) -> Void = { data in
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                return
            }
            errorBuffer.append(text)
        }

        // Every read from either pipe, whether a readability callback or the termination drain
        // below, runs on this one serial queue. That is what makes the drain complete: a callback
        // that already pulled bytes with `availableData` finishes appending them before the drain
        // starts, and a callback that lands after the drain finds the pipe at EOF. Detaching a
        // handler alone does not wait for an in-flight callback, so without the queue the final
        // stderr write could still be lost on a slow machine.
        let pipeReadQueue = DispatchQueue(label: "com.cotabby.aria2.pipe-read")

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            pipeReadQueue.sync { consumeOutput(handle.availableData) }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            pipeReadQueue.sync { consumeError(handle.availableData) }
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { [processState] terminatedProcess in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                // A process that exits right after its last write can terminate before the
                // readability callbacks consumed those bytes; on a slow machine that turned
                // "simulated aria failure" into a bare exit code. Drain both pipes to EOF on the
                // read queue, then snapshot the message on the same queue so nothing appends after
                // the snapshot. The drain cannot block: the child's write ends closed when it
                // exited, and the parent's copies were closed at launch.
                let errorMessage = pipeReadQueue.sync {
                    consumeOutput(outputPipe.fileHandleForReading.readDataToEndOfFile())
                    consumeError(errorPipe.fileHandleForReading.readDataToEndOfFile())
                    return errorBuffer.value
                }

                continuation.resume(
                    with: Self.completionResult(
                        status: terminatedProcess.terminationStatus,
                        stopIntent: processState.finish(),
                        errorMessage: errorMessage,
                        targetURL: targetURL
                    )
                )
            }

            do {
                // Launching while holding the state lock closes the cancel-before-run race:
                // cancellation either wins before launch or sees a running process to terminate.
                try processState.launch(process)
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private static func makeProcess(
        executableURL: URL,
        sourceURL: URL,
        filename: String,
        stagingDirectory: URL
    ) -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "-c",
            "-s", "8",
            "-x", "8",
            "-k", "1M",
            "--summary-interval=1",
            "--allow-overwrite=true",
            "--auto-file-renaming=false",
            "--dir=\(stagingDirectory.path)",
            "--out=\(filename)",
            sourceURL.absoluteString
        ]
        return process
    }

    private static func completionResult(
        status: Int32,
        stopIntent: DownloadStopIntent?,
        errorMessage: String,
        targetURL: URL
    ) -> Result<URL, Error> {
        if let interruption = Aria2ProcessState.interruption(for: stopIntent) {
            return .failure(interruption)
        }

        guard status == 0 else {
            let trimmedMessage = errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = trimmedMessage.isEmpty
                ? "Process terminated with exit code \(status)"
                : trimmedMessage
            return .failure(Aria2DownloadError.processFailed(exitCode: status, message: message))
        }
        return .success(targetURL)
    }
}

/// Serializes the stop intent, process publication, and launch as one state transition.
nonisolated private final class Aria2ProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopIntent: DownloadStopIntent?

    /// aria2 keeps its resume state in the staging directory's control file, so a pause never
    /// carries resume data.
    static func interruption(for stopIntent: DownloadStopIntent?) -> DownloadInterruption? {
        switch stopIntent {
        case .pause:
            return .paused(resumeData: nil)
        case .cancel:
            return .cancelled
        case nil:
            return nil
        }
    }

    func launch(_ process: Process) throws {
        try lock.withLock {
            if let interruption = Self.interruption(for: stopIntent) {
                throw interruption
            }

            self.process = process
            do {
                try process.run()
            } catch {
                self.process = nil
                throw error
            }
        }
    }

    func finish() -> DownloadStopIntent? {
        lock.withLock {
            process = nil
            return stopIntent
        }
    }

    func pause() {
        request(.pause)
    }

    func cancel() {
        request(.cancel)
    }

    private func request(_ requested: DownloadStopIntent) {
        lock.withLock {
            let intent = DownloadStopIntent.merging(stopIntent, with: requested)
            stopIntent = intent

            guard let process, process.isRunning else {
                return
            }
            switch intent {
            case .pause:
                process.interrupt()
            case .cancel:
                process.terminate()
            }
        }
    }
}

/// File-handle callbacks can arrive on different queues, so partial output is kept behind a lock.
nonisolated private final class LockedTextBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    var value: String {
        lock.withLock { storage }
    }

    func append(_ text: String) {
        lock.withLock {
            storage += text
        }
    }

    func appendAndTakeCompleteLines(_ text: String) -> [String] {
        lock.withLock {
            storage += text
            let components = storage.components(separatedBy: .newlines)
            guard components.count > 1 else {
                return []
            }
            storage = components.last ?? ""
            return Array(components.dropLast())
        }
    }
}
