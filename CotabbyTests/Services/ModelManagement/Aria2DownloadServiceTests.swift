import XCTest
@testable import Cotabby

/// Drives `Aria2DownloadService` against small shell scripts that impersonate aria2c, so the
/// subprocess contract (arguments, progress parsing, exit mapping, pause/cancel) is exercised
/// without the real binary or any network access.
final class Aria2DownloadServiceTests: XCTestCase {
    func test_downloadThrowsWhenInvalidExecutablePathProvided() async throws {
        let service = Aria2DownloadService { _ in }
        let invalidExecutable = URL(fileURLWithPath: "/non/existent/path/aria2c")
        let stagingDir = try makeStagingDirectoryURL()

        do {
            _ = try await service.download(
                from: URL(string: "https://example.com/model.gguf")!,
                filename: "model.gguf",
                stagingDirectory: stagingDir,
                executableURL: invalidExecutable
            )
            XCTFail("Expected error when providing nonexistent executable")
        } catch let error as Aria2DownloadError {
            XCTFail("Expected a process-launch error, got \(error)")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func test_aria2DownloadError_localizedDescription() {
        XCTAssertEqual(
            Aria2DownloadError.invalidFilename.errorDescription,
            "The model filename is not valid."
        )
        XCTAssertEqual(
            Aria2DownloadError.processFailed(exitCode: 1, message: "Network error").errorDescription,
            "aria2c download failed (exit code 1): Network error"
        )
    }

    func test_cancelBeforeLaunchReturnsCancelled() async {
        let service = Aria2DownloadService { _ in }
        service.cancel()

        do {
            _ = try await service.download(
                from: URL(string: "https://example.com/model.gguf")!,
                filename: "model.gguf",
                stagingDirectory: FileManager.default.temporaryDirectory,
                executableURL: URL(fileURLWithPath: "/usr/bin/false")
            )
            XCTFail("Expected cancellation")
        } catch let error as DownloadInterruption {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_pauseBeforeLaunchReturnsPaused() async {
        let service = Aria2DownloadService { _ in }
        service.pause()

        do {
            _ = try await service.download(
                from: URL(string: "https://example.com/model.gguf")!,
                filename: "model.gguf",
                stagingDirectory: FileManager.default.temporaryDirectory,
                executableURL: URL(fileURLWithPath: "/usr/bin/false")
            )
            XCTFail("Expected pause")
        } catch let error as DownloadInterruption {
            XCTAssertEqual(error, .paused(resumeData: nil))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_downloadRunsProcessAndReportsProgress() async throws {
        let executable = try makeWritingExecutable(
            beforeWrite: #"printf '[#abc123 1B/1B(100%%) CN:1 DL:1MiB ETA:0s]\n'"#
        )
        let stagingDirectory = try makeStagingDirectoryURL()
        let recorder = Locked<[Aria2Progress]>([])
        let service = Aria2DownloadService { progress in recorder.withLock { $0.append(progress) } }

        let result = try await service.download(
            from: URL(string: "https://example.com/model.gguf")!,
            filename: "model.gguf",
            stagingDirectory: stagingDirectory,
            executableURL: executable
        )

        XCTAssertEqual(result.lastPathComponent, "model.gguf")
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "model data")
        XCTAssertEqual(recorder.value.last?.progressFraction, 1)
        XCTAssertEqual(recorder.value.last?.speedFormatted, "1 MB/s")
    }

    func test_downloadReducesOutputToTheLeafFilename() async throws {
        let executable = try makeWritingExecutable()
        let stagingDirectory = try makeStagingDirectoryURL()
        let service = Aria2DownloadService { _ in }

        let result = try await service.download(
            from: URL(string: "https://example.com/model.gguf")!,
            filename: "../model.gguf",
            stagingDirectory: stagingDirectory,
            executableURL: executable
        )

        XCTAssertEqual(result, stagingDirectory.appendingPathComponent("model.gguf"))
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "model data")
    }

    /// Only a leaf name may reach `--out=`; anything that cannot name a file inside the staging
    /// directory is rejected before a process launches.
    func test_downloadRejectsFilenamesWithoutAUsableLeaf() async throws {
        let service = Aria2DownloadService { _ in }
        let stagingDirectory = try makeStagingDirectoryURL()

        for filename in ["", ".", "..", "/", "models/.."] {
            do {
                _ = try await service.download(
                    from: URL(string: "https://example.com/model.gguf")!,
                    filename: filename,
                    stagingDirectory: stagingDirectory,
                    executableURL: URL(fileURLWithPath: "/usr/bin/true")
                )
                XCTFail("Expected \"\(filename)\" to be rejected")
            } catch let error as Aria2DownloadError {
                XCTAssertEqual(error, .invalidFilename, filename)
            } catch {
                XCTFail("Unexpected error for \"\(filename)\": \(error)")
            }
        }
    }

    func test_downloadPassesSegmentedResumableArguments() async throws {
        let argumentsFile = try makeTemporaryDirectory().appendingPathComponent("arguments")
        let executable = try makeWritingExecutable(
            beforeWrite: #"for argument in "$@"; do printf '%s\n' "$argument"; done > "\#(argumentsFile.path)""#
        )
        let stagingDirectory = try makeStagingDirectoryURL()
        let service = Aria2DownloadService { _ in }

        _ = try await service.download(
            from: URL(string: "https://example.com/org/repo/model.gguf?download=true")!,
            filename: "model.gguf",
            stagingDirectory: stagingDirectory,
            executableURL: executable
        )

        let recorded = try String(contentsOf: argumentsFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .dropLast()
        XCTAssertEqual(Array(recorded), [
            "-c",
            "-s", "8",
            "-x", "8",
            "-k", "1M",
            "--summary-interval=1",
            "--allow-overwrite=true",
            "--auto-file-renaming=false",
            "--dir=\(stagingDirectory.path)",
            "--out=model.gguf",
            "https://example.com/org/repo/model.gguf?download=true"
        ])
    }

    func test_downloadWithSilentFailureReportsTheExitCode() async throws {
        let executable = try makeExecutableScript(contents: "#!/bin/sh\nexit 3\n")
        let stagingDirectory = try makeStagingDirectoryURL()
        let service = Aria2DownloadService { _ in }

        do {
            _ = try await service.download(
                from: URL(string: "https://example.com/model.gguf")!,
                filename: "model.gguf",
                stagingDirectory: stagingDirectory,
                executableURL: executable
            )
            XCTFail("Expected process failure")
        } catch let error as Aria2DownloadError {
            XCTAssertEqual(error, .processFailed(exitCode: 3, message: "Process terminated with exit code 3"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// Cancellation is the stronger intent: it overrides an earlier pause, and a later pause
    /// cannot downgrade it back to a resumable state.
    func test_cancelOverridesPauseInEitherOrder() async {
        for pauseFirst in [true, false] {
            let service = Aria2DownloadService { _ in }
            if pauseFirst {
                service.pause()
                service.cancel()
            } else {
                service.cancel()
                service.pause()
            }

            do {
                _ = try await service.download(
                    from: URL(string: "https://example.com/model.gguf")!,
                    filename: "model.gguf",
                    stagingDirectory: FileManager.default.temporaryDirectory,
                    executableURL: URL(fileURLWithPath: "/usr/bin/false")
                )
                XCTFail("Expected cancellation")
            } catch let error as DownloadInterruption {
                XCTAssertEqual(error, .cancelled, "pauseFirst: \(pauseFirst)")
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func test_downloadSurfacesProcessExitAndStderr() async throws {
        let executable = try makeExecutableScript(
            contents: """
            #!/bin/sh
            echo 'simulated aria failure' >&2
            exit 7
            """
        )
        let stagingDirectory = try makeStagingDirectoryURL()
        let service = Aria2DownloadService { _ in }

        do {
            _ = try await service.download(
                from: URL(string: "https://example.com/model.gguf")!,
                filename: "model.gguf",
                stagingDirectory: stagingDirectory,
                executableURL: executable
            )
            XCTFail("Expected process failure")
        } catch let error as Aria2DownloadError {
            XCTAssertEqual(
                error,
                .processFailed(exitCode: 7, message: "simulated aria failure")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_pauseStopsRunningProcessAsPaused() async throws {
        let executable = try makeLongRunningExecutable()
        let stagingDirectory = try makeStagingDirectoryURL()
        let recorder = Locked<[Aria2Progress]>([])
        let service = Aria2DownloadService { progress in recorder.withLock { $0.append(progress) } }
        let downloadTask = Task {
            try await service.download(
                from: URL(string: "https://example.com/model.gguf")!,
                filename: "model.gguf",
                stagingDirectory: stagingDirectory,
                executableURL: executable
            )
        }

        try await waitForProgress(recorder)
        service.pause()

        do {
            _ = try await downloadTask.value
            XCTFail("Expected pause")
        } catch let error as DownloadInterruption {
            XCTAssertEqual(error, .paused(resumeData: nil))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_cancelStopsRunningProcessAsCancelled() async throws {
        let executable = try makeLongRunningExecutable()
        let stagingDirectory = try makeStagingDirectoryURL()
        let recorder = Locked<[Aria2Progress]>([])
        let service = Aria2DownloadService { progress in recorder.withLock { $0.append(progress) } }
        let downloadTask = Task {
            try await service.download(
                from: URL(string: "https://example.com/model.gguf")!,
                filename: "model.gguf",
                stagingDirectory: stagingDirectory,
                executableURL: executable
            )
        }

        try await waitForProgress(recorder)
        service.cancel()

        do {
            _ = try await downloadTask.value
            XCTFail("Expected cancellation")
        } catch let error as DownloadInterruption {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeLongRunningExecutable() throws -> URL {
        try makeExecutableScript(
            contents: """
            #!/bin/sh
            trap 'exit 0' INT TERM
            printf '[#abc123 1B/10B(10%%) CN:1 DL:1MiB ETA:9s]\n'
            while true; do
                sleep 0.05
            done
            """
        )
    }

    /// A fake aria2c that honors `--dir=`/`--out=` by writing "model data" to that path, after
    /// running `beforeWrite` (a shell snippet that can emit progress or record arguments).
    private func makeWritingExecutable(beforeWrite: String = "") throws -> URL {
        try makeExecutableScript(
            contents: """
            #!/bin/sh
            directory=""
            output=""
            for argument in "$@"; do
                case "$argument" in
                    --dir=*) directory=${argument#--dir=} ;;
                    --out=*) output=${argument#--out=} ;;
                esac
            done
            \(beforeWrite)
            printf 'model data' > "$directory/$output"
            """
        )
    }

    private func makeExecutableScript(contents: String) throws -> URL {
        let url = try makeTemporaryDirectory().appendingPathComponent("fake-aria2")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A staging path that does not exist yet: the service must create it before aria2c writes there.
    private func makeStagingDirectoryURL() throws -> URL {
        try makeTemporaryDirectory().appendingPathComponent("staging")
    }

    private func waitForProgress(_ recorder: Locked<[Aria2Progress]>) async throws {
        for _ in 0..<200 {
            if !recorder.value.isEmpty {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(recorder.value.isEmpty, "The fake process never emitted progress")
    }
}
