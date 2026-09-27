import Foundation
import Logging
import XCTest
@testable import Cotabby

/// Locks the dedicated LLM I/O JSONL sink: full prompts and completions land as one valid JSON
/// record per generation under the fixed `llm-io` category (the `request_id` join contract with
/// the main log), and the writer rotates exactly like the main sink.
///
/// Every writer targets a per-test temp directory, never the user's real log location.
final class LLMIOFileHandlerTests: XCTestCase {
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

    private var logURL: URL { directory.appendingPathComponent("llm-io.jsonl") }
    private var rotatedURL: URL { directory.appendingPathComponent("llm-io.jsonl.1") }

    private func makeWriter(cap: UInt64? = nil) -> LLMIOFileWriter {
        LLMIOFileWriter(sizeCapBytes: cap, fileURL: logURL)
    }

    private func emit(
        _ handler: LLMIOFileHandler,
        level: Logging.Logger.Level = .info,
        message: Logging.Logger.Message = "generation",
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

    func test_log_emitsLLMIORecordWithPromptAndCompletionMetadata() throws {
        let writer = makeWriter()
        var handler = LLMIOFileHandler(label: CotabbyLogger.llmIOLabel, writer: writer)
        handler[metadataKey: "engine"] = .string("llama")
        XCTAssertEqual(handler[metadataKey: "engine"], .string("llama"))
        emit(handler, metadata: [
            "request_id": .string("req_join42"),
            // Multi-line prompts must stay inside one JSONL record.
            "prompt": .string("Dear team,\nThe quick brown"),
            "completion": .string(" fox jumps"),
            "token_counts": .dictionary(["prompt": .stringConvertible(3)]),
            "stops": .array([.string("\n")])
        ])

        XCTAssertEqual(lines(of: try XCTUnwrap(writer.fileURL)).count, 1)
        let record = try XCTUnwrap(try records(of: logURL).first)
        XCTAssertEqual(record["category"] as? String, "llm-io")
        XCTAssertEqual(record["level"] as? String, "info")
        XCTAssertEqual(record["message"] as? String, "generation")
        XCTAssertEqual(record["request_id"] as? String, "req_join42")
        XCTAssertEqual(record["prompt"] as? String, "Dear team,\nThe quick brown")
        XCTAssertEqual(record["completion"] as? String, " fox jumps")
        XCTAssertEqual((record["token_counts"] as? [String: Any])?["prompt"] as? String, "3")
        XCTAssertEqual(record["stops"] as? [String], ["\n"])
        XCTAssertEqual(record["engine"] as? String, "llama")
        XCTAssertNotNil(record["timestamp"] as? String)
    }

    func test_log_categoryIsFixedRegardlessOfLabel() throws {
        // Unlike FileLogHandler, the category is not derived from the label: every record in this
        // file is an LLM I/O record by construction.
        let writer = makeWriter()
        emit(LLMIOFileHandler(label: "com.cotabby.runtime", writer: writer))
        emit(LLMIOFileHandler(label: "anything", writer: writer))

        let categories = try records(of: logURL).map { $0["category"] as? String ?? "<missing>" }
        XCTAssertEqual(categories, ["llm-io", "llm-io"])
    }

    func test_log_eventMetadataWinsOverHandlerMetadataOnCollision() throws {
        var handler = LLMIOFileHandler(label: CotabbyLogger.llmIOLabel, writer: makeWriter())
        handler[metadataKey: "engine"] = .string("from_handler")
        emit(handler, metadata: ["engine": .string("from_event")])

        let record = try XCTUnwrap(try records(of: logURL).first)
        XCTAssertEqual(record["engine"] as? String, "from_event")
    }

    func test_logLevel_defaultsToTraceSoEveryRoutedEventIsKept() {
        // Everything routed to `CotabbyLogger.llmIO` is intentional, so the handler never filters.
        XCTAssertEqual(LLMIOFileHandler(label: CotabbyLogger.llmIOLabel, writer: makeWriter()).logLevel, .trace)
    }

    // MARK: - Writer rotation

    func test_writer_rotatesPastTheCapKeepingPreviousHistory() throws {
        let writer = makeWriter(cap: 32)
        let longLine = String(repeating: "p", count: 40)
        writer.write(longLine + "\n")
        writer.write("after-cap\n")

        XCTAssertEqual(try XCTUnwrap(writer.fileURL), logURL)
        XCTAssertEqual(lines(of: logURL), ["after-cap"])
        XCTAssertEqual(lines(of: rotatedURL), [longLine])
    }

    func test_writer_doesNotRotateWhileBelowTheCap() {
        // "12345\n" is 6 bytes; the check is `offset >= cap`, so a cap of 7 still has room.
        let writer = makeWriter(cap: 7)
        writer.write("12345\n")
        writer.write("x\n")

        XCTAssertEqual(lines(of: logURL), ["12345", "x"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotatedURL.path))
    }

    func test_writer_secondRotationReplacesThePreviousRotatedFile() {
        let writer = makeWriter(cap: 8)

        writer.write("aaaaaaaaa\n")
        writer.write("bbbbbbbbb\n") // rotates: .1 = a
        writer.write("c\n") // rotates again: .1 = b

        XCTAssertEqual(lines(of: logURL), ["c"])
        XCTAssertEqual(lines(of: rotatedURL), ["bbbbbbbbb"])
    }

    func test_writer_appendsAcrossInstancesAndRotatesAnOversizedFileOnRelaunch() {
        makeWriter().write("first\n")
        makeWriter().write("second\n")
        XCTAssertEqual(lines(of: logURL), ["first", "second"], "A relaunch must append, not truncate")

        // "first\nsecond\n" is 13 bytes, already past a 10-byte cap, so the next writer rotates it.
        makeWriter(cap: 10).write("third\n")
        XCTAssertEqual(lines(of: logURL), ["third"])
        XCTAssertEqual(lines(of: rotatedURL), ["first", "second"])
    }
}
