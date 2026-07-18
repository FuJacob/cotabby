import Foundation
import Logging
import XCTest
@testable import Cotabby

/// Locks the dedicated LLM I/O JSONL sink: full prompts and completions land as one valid JSON
/// record per generation under the fixed `llm-io` category (the `request_id` join contract with
/// the main log), and the writer rotates exactly like the main sink.
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

    private func makeWriter(cap: UInt64? = nil) -> LLMIOFileWriter {
        LLMIOFileWriter(sizeCapBytes: cap, fileURL: directory.appendingPathComponent("llm-io.jsonl"))
    }

    private func lines(of url: URL) -> [String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").map(String.init)
    }

    func test_log_emitsLLMIORecordWithPromptAndCompletionMetadata() throws {
        let writer = makeWriter()
        var handler = LLMIOFileHandler(label: "com.cotabby.llm-io", writer: writer)
        handler[metadataKey: "engine"] = .string("llama")
        XCTAssertEqual(handler[metadataKey: "engine"], .string("llama"))
        handler.log(event: LogEvent(
            level: .info,
            message: "generation",
            metadata: [
                "request_id": .string("req_join42"),
                "prompt": .string("The quick brown"),
                "completion": .string(" fox jumps"),
                "token_counts": .dictionary(["prompt": .stringConvertible(3)]),
                "stops": .array([.string("\n")])
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
        XCTAssertEqual(record["category"] as? String, "llm-io")
        XCTAssertEqual(record["request_id"] as? String, "req_join42")
        XCTAssertEqual(record["prompt"] as? String, "The quick brown")
        XCTAssertEqual(record["completion"] as? String, " fox jumps")
        XCTAssertEqual((record["token_counts"] as? [String: Any])?["prompt"] as? String, "3")
        XCTAssertEqual(record["stops"] as? [String], ["\n"])
        XCTAssertEqual(record["engine"] as? String, "llama")
    }

    func test_writer_rotatesPastTheCapKeepingPreviousHistory() throws {
        let writer = makeWriter(cap: 32)
        writer.write(String(repeating: "p", count: 40) + "\n")
        writer.write("after-cap\n")

        let url = try XCTUnwrap(writer.fileURL)
        let rotatedURL = url.deletingPathExtension().appendingPathExtension("jsonl.1")
        XCTAssertEqual(lines(of: url), ["after-cap"])
        XCTAssertEqual(lines(of: rotatedURL), [String(repeating: "p", count: 40)])
    }
}
