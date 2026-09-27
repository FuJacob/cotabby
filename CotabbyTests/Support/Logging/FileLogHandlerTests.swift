import Foundation
import Logging
import XCTest
@testable import Cotabby

/// Locks the JSONL debug sink: one valid JSON object per line with metadata flattened to
/// top-level keys (the `jq` contract the debugging docs promise), and one-step size rotation
/// that preserves the previous file as `.jsonl.1` instead of truncating recent history.
///
/// Every writer targets a per-test temp directory, so nothing ever touches the user's real
/// `~/Library/Logs/Cotabby/` files.
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

    // MARK: - Helpers

    private var logURL: URL { directory.appendingPathComponent("cotabby.jsonl") }
    private var rotatedURL: URL { directory.appendingPathComponent("cotabby.jsonl.1") }

    private func makeWriter(cap: UInt64? = nil) -> FileLogWriter {
        FileLogWriter(sizeCapBytes: cap, fileURL: logURL)
    }

    private func emit(
        _ handler: FileLogHandler,
        level: Logging.Logger.Level = .info,
        message: Logging.Logger.Message = "event",
        metadata: Logging.Logger.Metadata? = nil
    ) {
        handler.log(event: LogEvent(
            level: level,
            message: message,
            metadata: metadata,
            source: "CotabbyTests",
            file: #filePath,
            function: #function,
            line: #line
        ))
    }

    private func lines(of url: URL) -> [String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").map(String.init)
    }

    private func records(of url: URL) throws -> [[String: Any]] {
        try lines(of: url).map { line in
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                "Not a JSON object: \(line)"
            )
        }
    }

    // MARK: - Record shape

    func test_log_emitsOneValidJSONObjectPerLineWithFlattenedMetadata() throws {
        let writer = makeWriter()
        var handler = FileLogHandler(label: "com.cotabby.suggestion", writer: writer, logLevel: .trace)
        handler[metadataKey: "handler_key"] = .string("handler_value")
        XCTAssertEqual(handler[metadataKey: "handler_key"], .string("handler_value"))
        emit(handler, message: "Suggestion ready", metadata: [
            "request_id": .string("req_test1234"),
            "latency_ms": .stringConvertible(42),
            "nested": .dictionary(["inner": .string("x")]),
            "list": .array([.string("a"), .string("b")]),
            // Recursion through arrays inside dictionaries (and dictionaries inside those arrays).
            "deep": .dictionary(["tags": .array([.stringConvertible(1), .dictionary(["k": .string("v")])])])
        ])

        let written = try records(of: try XCTUnwrap(writer.fileURL))
        XCTAssertEqual(written.count, 1)
        let record = written[0]
        XCTAssertEqual(record["category"] as? String, "suggestion")
        XCTAssertEqual(record["level"] as? String, "info")
        XCTAssertEqual(record["message"] as? String, "Suggestion ready")
        XCTAssertEqual(record["request_id"] as? String, "req_test1234")
        XCTAssertEqual(record["latency_ms"] as? String, "42")
        XCTAssertEqual((record["nested"] as? [String: Any])?["inner"] as? String, "x")
        XCTAssertEqual(record["list"] as? [String], ["a", "b"])
        XCTAssertEqual(record["handler_key"] as? String, "handler_value")

        let tags = try XCTUnwrap((record["deep"] as? [String: Any])?["tags"] as? [Any])
        XCTAssertEqual(tags.count, 2)
        XCTAssertEqual(tags[0] as? String, "1")
        XCTAssertEqual((tags[1] as? [String: Any])?["k"] as? String, "v")

        // The handler stamps its own ISO-8601 time with fractional seconds.
        let timestamp = try XCTUnwrap(record["timestamp"] as? String)
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertNotNil(parser.date(from: timestamp), "Unparseable timestamp \(timestamp)")
    }

    func test_log_eventMetadataWinsOverHandlerMetadataOnCollision() throws {
        let writer = makeWriter()
        var handler = FileLogHandler(label: "com.cotabby.focus", writer: writer, logLevel: .trace)
        handler[metadataKey: "shared"] = .string("from_handler")
        emit(handler, level: .warning, metadata: ["shared": .string("from_event")])

        let record = try XCTUnwrap(try records(of: logURL).first)
        XCTAssertEqual(record["shared"] as? String, "from_event")
        XCTAssertEqual(record["level"] as? String, "warning")
    }

    func test_log_derivesCategoryFromTheThirdLabelComponent() throws {
        // Mirrors OSLogHandler so the JSON `category` matches Console.app. `maxSplits: 2` keeps any
        // deeper components joined; labels without the reverse-DNS shape pass through unchanged.
        let cases: [(label: String, category: String)] = [
            ("com.cotabby.runtime", "runtime"),
            ("com.cotabby.runtime.decode", "runtime.decode"),
            ("com.cotabby", "com.cotabby"),
            ("short-label", "short-label")
        ]
        let writer = makeWriter()
        for testCase in cases {
            emit(FileLogHandler(label: testCase.label, writer: writer, logLevel: .trace))
        }

        let categories = try records(of: logURL).map { $0["category"] as? String ?? "<missing>" }
        XCTAssertEqual(categories, cases.map { $0.category })
    }

    func test_log_escapesControlCharactersSoEachRecordStaysOneLine() throws {
        let writer = makeWriter()
        let handler = FileLogHandler(label: "com.cotabby.app", writer: writer, logLevel: .trace)
        let message = "line1\nline2 \"quoted\" back\\slash 🐱"
        emit(handler, message: "\(message)", metadata: ["path": .string("/Users/me/file.txt")])

        let raw = lines(of: logURL)
        XCTAssertEqual(raw.count, 1, "An embedded newline must be escaped, not split the record")
        // `.withoutEscapingSlashes` keeps paths greppable; `.sortedKeys` makes line layout stable.
        XCTAssertTrue(raw[0].contains("\"path\":\"/Users/me/file.txt\""), raw[0])
        XCTAssertTrue(raw[0].hasPrefix("{\"category\":"), raw[0])

        let record = try XCTUnwrap(try records(of: logURL).first)
        XCTAssertEqual(record["message"] as? String, message)
    }

    func test_logLevel_defaultsToTheGlobalFloorAndAcceptsAnOverride() {
        let writer = makeWriter()

        XCTAssertEqual(
            FileLogHandler(label: "com.cotabby.app", writer: writer).logLevel,
            CotabbyDebugOptions.minimumLogLevel
        )
        XCTAssertEqual(
            FileLogHandler(label: "com.cotabby.app", writer: writer, logLevel: .error).logLevel,
            .error
        )
    }

    // MARK: - Writer rotation

    func test_writer_rotatesPastTheCapKeepingPreviousHistory() throws {
        let writer = makeWriter(cap: 64)
        let line = String(repeating: "a", count: 40)

        writer.write(line + "\n")
        writer.write(line + "\n")
        // The third write finds the offset past the cap: the existing file must move to .jsonl.1
        // and the new line start a fresh file, so the most recent history survives the cap.
        writer.write("fresh\n")

        XCTAssertEqual(try XCTUnwrap(writer.fileURL), logURL)
        XCTAssertEqual(lines(of: logURL), ["fresh"])
        XCTAssertEqual(lines(of: rotatedURL), [line, line])
    }

    func test_writer_rotatesOnceTheOffsetReachesTheCapExactly() {
        // "12345\n" is 6 bytes. The check is `offset >= cap`, so a cap of 6 rotates on the next
        // write while a cap of 7 still has room.
        for (cap, rotates) in [(UInt64(6), true), (UInt64(7), false)] {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: rotatedURL)
            let writer = makeWriter(cap: cap)

            writer.write("12345\n")
            writer.write("x\n")

            if rotates {
                XCTAssertEqual(lines(of: logURL), ["x"], "cap \(cap)")
                XCTAssertEqual(lines(of: rotatedURL), ["12345"], "cap \(cap)")
            } else {
                XCTAssertEqual(lines(of: logURL), ["12345", "x"], "cap \(cap)")
                XCTAssertFalse(FileManager.default.fileExists(atPath: rotatedURL.path), "cap \(cap)")
            }
        }
    }

    func test_writer_secondRotationReplacesThePreviousRotatedFile() {
        let writer = makeWriter(cap: 8)

        writer.write("aaaaaaaaa\n")
        writer.write("bbbbbbbbb\n") // rotates: .1 = a
        writer.write("c\n") // rotates again: .1 = b, the older a history is discarded

        XCTAssertEqual(lines(of: logURL), ["c"])
        XCTAssertEqual(lines(of: rotatedURL), ["bbbbbbbbb"])
    }

    func test_writer_appendsAcrossInstancesLikeARelaunch() {
        makeWriter().write("first\n")

        // A second writer (a relaunch) must append after the existing bytes, not truncate.
        makeWriter().write("second\n")

        XCTAssertEqual(lines(of: logURL), ["first", "second"])
    }

    func test_writer_relaunchOntoAnOversizedFileRotatesBeforeTheFirstWrite() throws {
        // The byte offset is seeded from the existing file size, so a relaunch that finds a file
        // already past the cap rotates it instead of growing it further.
        try Data((String(repeating: "o", count: 19) + "\n").utf8).write(to: logURL)

        makeWriter(cap: 10).write("new\n")

        XCTAssertEqual(lines(of: logURL), ["new"])
        XCTAssertEqual(lines(of: rotatedURL), [String(repeating: "o", count: 19)])
    }

    func test_writer_createsMissingParentDirectories() {
        let nestedURL = directory
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("deeper", isDirectory: true)
            .appendingPathComponent("cotabby.jsonl")

        FileLogWriter(sizeCapBytes: nil, fileURL: nestedURL).write("hello\n")

        XCTAssertEqual(lines(of: nestedURL), ["hello"])
    }
}
