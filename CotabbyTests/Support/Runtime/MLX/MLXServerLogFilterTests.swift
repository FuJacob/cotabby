import XCTest
@testable import Cotabby

/// Pins the stderr noise filter and the "generator died" classifier with a realistic mlx_lm.server
/// transcript: access-log lines, an early-disconnect BrokenPipe traceback, then the real failure.
final class MLXServerLogFilterTests: XCTestCase {
    private let access = #"127.0.0.1 - - [14/Oct/2026 10:00:01] "POST /v1/completions HTTP/1.1" 200 -"#
    private let brokenPipe = [
        "----------------------------------------",
        "Exception occurred during processing of request from ('127.0.0.1', 51234)",
        "Traceback (most recent call last):",
        #"  File "/python/lib/python3.12/socketserver.py", line 318, in _handle_request_noblock"#,
        "    self.process_request(request, client_address)",
        #"  File "/python/lib/python3.12/socketserver.py", line 766, in finish"#,
        "    self.wfile.flush()",
        "BrokenPipeError: [Errno 32] Broken pipe",
        "----------------------------------------"
    ]
    private let reset = [
        "Traceback (most recent call last):",
        #"  File "/python/lib/python3.12/socketserver.py", line 318, in handle"#,
        "    self.rfile.readline()",
        "ConnectionResetError: [Errno 54] Connection reset by peer"
    ]
    private let real = [
        "mlx_lm.server generation thread died: Resource limit exceeded",
        "Traceback (most recent call last):",
        #"  File "/mlx_lm/server.py", line 700, in _run_generate"#,
        "    response = next(gen)",
        "RuntimeError: [metal::malloc] Resource limit exceeded"
    ]

    func test_dropsAccessLines() {
        XCTAssertEqual(MLXServerLogFilter.relevantTail([access, "real line", access], limit: 20), ["real line"])
    }

    func test_dropsWholeBrokenPipeAndResetBlocksButKeepsTheRealFailure() {
        let lines = [access] + brokenPipe + [access] + reset + [access] + real
        XCTAssertEqual(MLXServerLogFilter.relevantTail(lines, limit: 20), real)
    }

    func test_keepsATracebackWithAnotherError() {
        let lines = brokenPipe + real
        let kept = MLXServerLogFilter.relevantTail(lines, limit: 50)
        XCTAssertEqual(kept, real)
        XCTAssertTrue(kept.contains("RuntimeError: [metal::malloc] Resource limit exceeded"))
    }

    func test_keepsTheLastLimitLinesAfterFiltering() {
        let lines = (1...30).map { "line \($0)" } + [access]
        let kept = MLXServerLogFilter.relevantTail(lines, limit: 5)
        XCTAssertEqual(kept, (26...30).map { "line \($0)" })
    }

    func test_anUnfinishedTracebackIsKept() {
        let partial = ["Traceback (most recent call last):", #"  File "x.py", line 1, in f"#]
        XCTAssertEqual(MLXServerLogFilter.relevantTail(partial, limit: 20), partial)
    }

    func test_classifiesGeneratorDeath() {
        XCTAssertEqual(MLXGeneratorFailure.reason(for: OpenAICompatibleClientError.server(statusCode: 404)), "HTTP 404")
        // mlx_lm never answers 500; only 404 is a suspect.
        XCTAssertNil(MLXGeneratorFailure.reason(for: OpenAICompatibleClientError.server(statusCode: 500)))
        XCTAssertEqual(
            MLXGeneratorFailure.reason(for: OpenAICompatibleClientError.streamError("generation thread died: x")),
            "generation thread died")
        XCTAssertNil(MLXGeneratorFailure.reason(for: OpenAICompatibleClientError.server(statusCode: 401)))
        XCTAssertNil(MLXGeneratorFailure.reason(for: OpenAICompatibleClientError.streamError("model missing")))
        XCTAssertNil(MLXGeneratorFailure.reason(for: URLError(.timedOut)))
    }
}

/// The server log file: header line per start, raw stderr appended, one-step rotation at the cap.
final class MLXServerLogWriterTests: XCTestCase {
    func test_rotatesOnceAtTheSizeCapAndWritesHeaders() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mlx-server.log")
        let writer = MLXServerLogWriter(fileURL: url, sizeCapBytes: 200)

        writer.writeHeader(pid: 42, model: "org/m", port: 50123, date: Date(timeIntervalSince1970: 0))
        let header = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(header.contains("pid=42") && header.contains("model=org/m") && header.contains("port=50123"), header)

        writer.write(Data(String(repeating: "a", count: 250).utf8) + Data("\n".utf8))
        // Over the cap: the next write moves the old file to .1 and starts a fresh one.
        writer.write(Data("fresh line\n".utf8))
        let rotated = try String(contentsOf: directory.appendingPathComponent("mlx-server.log.1"), encoding: .utf8)
        XCTAssertTrue(rotated.contains("pid=42"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "fresh line\n")
    }
}
