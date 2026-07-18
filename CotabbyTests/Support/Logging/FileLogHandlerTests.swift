import Foundation
import Logging
import XCTest
@testable import Cotabby

/// Locks the JSONL debug sink: one valid JSON object per line with metadata flattened to
/// top-level keys (the `jq` contract the debugging docs promise), and one-step size rotation
/// that preserves the previous file as `.jsonl.1` instead of truncating recent history.
final class FileLogHandlerTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    private func makeWriter(cap: UInt64? = nil) -> FileLogWriter {
        FileLogWriter(sizeCapBytes: cap, fileURL: directory.appendingPathComponent("cotabby.jsonl"))
    }

    private func lines(of url: URL) -> [String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").map(String.init)
    }

    func test_log_emitsOneValidJSONObjectPerLineWithFlattenedMetadata() throws {
        let writer = makeWriter()
        var handler = FileLogHandler(label: "com.cotabby.suggestion", writer: writer, logLevel: .trace)
        handler[metadataKey: "handler_key"] = .string("handler_value")
        XCTAssertEqual(handler[metadataKey: "handler_key"], .string("handler_value"))
        handler.log(event: LogEvent(
            level: .info,
            message: "Suggestion ready",
            metadata: [
                "request_id": .string("req_test1234"),
                "latency_ms": .stringConvertible(42),
                "nested": .dictionary(["inner": .string("x")]),
                "list": .array([.string("a"), .string("b")])
            ],
            source: "CotabbyTests",
            file: #filePath,
            function: #function,
            line: #line
        ))

        let url = try XCTUnwrap(writer.fileURL)
        let written = lines(of: url)
        XCTAssertEqual(written.count, 1)
        let record = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(written[0].utf8)) as? [String: Any]
        )
        XCTAssertEqual(record["category"] as? String, "suggestion")
        XCTAssertEqual(record["level"] as? String, "info")
        XCTAssertEqual(record["message"] as? String, "Suggestion ready")
        XCTAssertEqual(record["request_id"] as? String, "req_test1234")
        XCTAssertEqual(record["latency_ms"] as? String, "42")
        XCTAssertEqual((record["nested"] as? [String: Any])?["inner"] as? String, "x")
        XCTAssertEqual(record["list"] as? [String], ["a", "b"])
        XCTAssertEqual(record["handler_key"] as? String, "handler_value")
        XCTAssertNotNil(record["timestamp"])
    }

    func test_log_eventMetadataWinsOverHandlerMetadataOnCollision() throws {
        let writer = makeWriter()
        var handler = FileLogHandler(label: "short-label", writer: writer, logLevel: .trace)
        handler[metadataKey: "shared"] = .string("from_handler")
        handler.log(event: LogEvent(
            level: .warning,
            message: "collide",
            metadata: ["shared": .string("from_event")],
            source: "CotabbyTests",
            file: #filePath,
            function: #function,
            line: #line
        ))

        let url = try XCTUnwrap(writer.fileURL)
        let record = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines(of: url)[0].utf8)) as? [String: Any]
        )
        XCTAssertEqual(record["shared"] as? String, "from_event")
        // A label without the reverse-DNS shape passes through unchanged.
        XCTAssertEqual(record["category"] as? String, "short-label")
    }

    func test_writer_rotatesPastTheCapKeepingPreviousHistory() throws {
        let writer = makeWriter(cap: 64)
        let line = String(repeating: "a", count: 40) + "\n"

        writer.write(line)
        writer.write(line)
        // The third write finds the offset past the cap: the existing file must move to .jsonl.1
        // and the new line start a fresh file, so the most recent history survives the cap.
        writer.write("fresh\n")

        let url = try XCTUnwrap(writer.fileURL)
        let rotatedURL = url.deletingPathExtension().appendingPathExtension("jsonl.1")
        XCTAssertEqual(lines(of: url), ["fresh"])
        XCTAssertEqual(lines(of: rotatedURL).count, 2)
        XCTAssertTrue(lines(of: rotatedURL).allSatisfy { $0 == String(repeating: "a", count: 40) })
    }

    func test_writer_appendsAcrossInstancesLikeARelaunch() throws {
        let url = directory.appendingPathComponent("cotabby.jsonl")
        FileLogWriter(sizeCapBytes: nil, fileURL: url).write("first\n")

        // A second writer (a relaunch) must append after the existing bytes, not truncate.
        FileLogWriter(sizeCapBytes: nil, fileURL: url).write("second\n")

        XCTAssertEqual(lines(of: url), ["first", "second"])
    }
}
