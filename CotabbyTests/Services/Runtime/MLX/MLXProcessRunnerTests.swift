import XCTest
@testable import Cotabby

/// Real short-lived processes (/bin/sh, /bin/sleep): exit status, output capture, timeouts,
/// cancellation, and a child that writes more than a pipe buffer holds.
final class MLXProcessRunnerTests: XCTestCase {
    private let sh = URL(fileURLWithPath: "/bin/sh")

    func test_returnsStatusAndStdout() async throws {
        let result = try await MLXProcessRunner.run(
            executable: sh, arguments: ["-c", "printf hello; exit 3"], environment: [:], timeout: .seconds(5))
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stdout, "hello")
    }

    func test_keepsTheLastStderrLines() async throws {
        let result = try await MLXProcessRunner.run(
            executable: sh,
            arguments: ["-c", "i=1; while [ $i -le 30 ]; do echo line$i >&2; i=$((i+1)); done"],
            environment: [:], timeout: .seconds(5))
        XCTAssertEqual(result.stderrTail.count, 20)
        XCTAssertEqual(result.stderrTail.first, "line11")
        XCTAssertEqual(result.stderrTail.last, "line30")
    }

    func test_passesTheEnvironment() async throws {
        let result = try await MLXProcessRunner.run(
            executable: sh, arguments: ["-c", "printf \"$FOO\""], environment: ["FOO": "bar"], timeout: .seconds(5))
        XCTAssertEqual(result.stdout, "bar")
    }

    func test_largeOutputDoesNotDeadlockAndIsCapped() async throws {
        let result = try await MLXProcessRunner.run(
            executable: sh, arguments: ["-c", "head -c 3000000 /dev/zero | tr '\\0' a"],
            environment: [:], timeout: .seconds(20))
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.utf8.count, 1 << 20)
    }

    func test_timeoutTerminatesTheChild() async {
        let start = Date()
        do {
            _ = try await MLXProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:],
                timeout: .milliseconds(300))
            XCTFail("expected a timeout")
        } catch MLXProcessRunnerError.timedOut {
            XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_cancellationTerminatesTheChild() async {
        let task = Task {
            try await MLXProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:],
                timeout: .seconds(60))
        }
        try? await Task.sleep(for: .milliseconds(200))
        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    /// A grandchild that keeps the pipe open must not stretch the run past the timeout grace.
    func test_grandchildHoldingThePipeDoesNotBlock() async {
        let start = Date()
        do {
            _ = try await MLXProcessRunner.run(
                executable: sh, arguments: ["-c", "sleep 30 & echo started; sleep 30"], environment: [:],
                timeout: .milliseconds(500))
            XCTFail("expected a timeout")
        } catch MLXProcessRunnerError.timedOut {
            XCTAssertLessThan(Date().timeIntervalSince(start), 6)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_missingExecutableIsALaunchFailure() async {
        do {
            _ = try await MLXProcessRunner.run(
                executable: URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], environment: [:],
                timeout: .seconds(1))
            XCTFail("expected a launch failure")
        } catch MLXProcessRunnerError.launchFailed {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

/// The collector splits stderr into lines as bytes, so pipe reads that cut a character in half
/// or redraw a progress line with `\r` still give whole, readable lines.
final class MLXOutputCollectorTests: XCTestCase {
    func test_characterSplitAcrossReadsIsDecodedWhole() {
        let collector = MLXOutputCollector(tailLines: 5)
        let bytes = Array("Grüße\n".utf8)
        // "ü" is two bytes; the first read ends between them.
        collector.appendStderr(Data(bytes[..<3]))
        collector.appendStderr(Data(bytes[3...]))
        XCTAssertEqual(collector.stderrTail, ["Grüße"])
    }

    func test_carriageReturnsSplitLinesAndTheUnterminatedTailIsKept() {
        let collector = MLXOutputCollector(tailLines: 5)
        collector.appendStderr(Data("10%\r50%\r\nDone\npartial".utf8))
        XCTAssertEqual(collector.stderrTail, ["10%", "50%", "Done", "partial"])
    }

    func test_invalidUTF8IsReportedBySize() {
        let collector = MLXOutputCollector(tailLines: 5)
        collector.appendStderr(Data([0xFF, 0xFE, UInt8(ascii: "\n")]))
        XCTAssertEqual(collector.stderrTail, ["<2 bytes of non-UTF-8 output>"])
    }
}
