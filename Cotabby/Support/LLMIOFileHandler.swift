import Foundation
import Logging

/// File overview:
/// Dedicated JSONL sink for full LLM prompts and completions.
///
/// Kept separate from `cotabby.jsonl` so the main event stream stays readable: a single generation
/// can carry several KB of prompt text, and inlining that into every other log line would drown
/// the orchestration signal an AI debugger actually wants to follow.
///
/// One record per generation, written to `~/Library/Logs/Cotabby/llm-io.jsonl`. Records share a
/// `request_id` with the main log so a debugger can join across files.
///
/// Like `FileLogHandler`, this handler is only installed when `-cotabby-debug` is set, so a release
/// build never touches the user's disk with prompt or completion text.
final class LLMIOFileWriter: @unchecked Sendable {
    static let shared = LLMIOFileWriter()

    /// Same 10 MB cap as the main log. LLM I/O records are larger per line, so this corresponds to
    /// fewer events — fine for the debug-only use case.
    private let sizeCapBytes: UInt64 = 10 * 1024 * 1024

    private let lock = NSLock()
    private let logFileURL: URL?
    private var handle: FileHandle?
    private var currentByteOffset: UInt64 = 0

    init(sizeCapBytes: UInt64? = nil) {
        self.sizeCapBytesOverride = sizeCapBytes
        self.logFileURL = Self.makeLogFileURL()
        openHandle()
    }

    private let sizeCapBytesOverride: UInt64?
    private var effectiveCap: UInt64 { sizeCapBytesOverride ?? sizeCapBytes }

    var fileURL: URL? { logFileURL }

    func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }

        if currentByteOffset >= effectiveCap {
            rotateLocked()
        }

        guard let handle else { return }

        do {
            try handle.write(contentsOf: data)
            currentByteOffset += UInt64(data.count)
        } catch {
            // Debug-only sink. Failing to write must never disrupt the app.
        }
    }

    /// One-step rotation: rename the current file to `*.1` (overwriting any prior rotation), then
    /// open a fresh empty file. Keeps roughly the last 2× cap of history instead of the previous
    /// truncate-to-zero, which destroyed the *most recent* logs the moment the cap was hit.
    private func rotateLocked() {
        guard let logFileURL else { return }
        do {
            try handle?.close()
        } catch {
            // Closing a stale handle should not block re-opening a fresh one.
        }
        handle = nil
        // Only overwrite with a fresh empty file when the rotation actually displaced the old
        // one. A silent `moveItem` failure (transient FS error, concurrent external rewrite)
        // would otherwise destroy the live log we just failed to preserve.
        let didRotate = rotateOnDisk(currentURL: logFileURL)
        if didRotate {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        openHandleLocked()
    }

    private func rotateOnDisk(currentURL: URL) -> Bool {
        let fileManager = FileManager.default
        let rotatedURL = currentURL.deletingPathExtension()
            .appendingPathExtension("jsonl.1")
        if fileManager.fileExists(atPath: rotatedURL.path) {
            try? fileManager.removeItem(at: rotatedURL)
        }
        guard fileManager.fileExists(atPath: currentURL.path) else {
            return true
        }
        do {
            try fileManager.moveItem(at: currentURL, to: rotatedURL)
            return true
        } catch {
            return false
        }
    }

    private func openHandle() {
        lock.lock()
        defer { lock.unlock() }
        openHandleLocked()
    }

    private func openHandleLocked() {
        guard let logFileURL else { return }
        let fileManager = FileManager.default
        let directory = logFileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: logFileURL)
        currentByteOffset = (try? handle?.seekToEnd()) ?? 0
    }

    private static func makeLogFileURL() -> URL? {
        let fileManager = FileManager.default
        guard let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        let bundleName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Cotabby"
        let directory = libraryURL
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(bundleName, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("llm-io.jsonl")
    }
}

/// swift-log handler that mirrors `FileLogHandler` but writes to the separate LLM I/O file. The
/// caller is expected to pass the full prompt and completion text via `Logger.Metadata`; the
/// handler does not inspect log levels because every event routed to `CotabbyLogger.llmIO` is
/// intentional.
struct LLMIOFileHandler: LogHandler {
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .trace

    private let label: String
    private let writer: LLMIOFileWriter

    init(label: String, writer: LLMIOFileWriter = .shared) {
        self.label = label
        self.writer = writer
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: borrowing Logging.LogEvent) {
        // See FileLogHandler for the matching note: swift-log's `LogEvent` has no emission
        // timestamp, so the handler stamps its own.
        let timestamp = ISO8601DateFormatter.llmIOShared.string(from: Date())

        var record: [String: Any] = [
            "timestamp": timestamp,
            "level": "\(event.level)",
            "category": "llm-io",
            "message": "\(event.message)"
        ]

        if let eventMetadata = event.metadata {
            for (key, value) in eventMetadata {
                record[key] = Self.jsonValue(of: value)
            }
        }
        for (key, value) in metadata where record[key] == nil {
            record[key] = Self.jsonValue(of: value)
        }

        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        writer.write(json + "\n")
    }

    private static func jsonValue(of value: Logging.Logger.Metadata.Value) -> Any {
        switch value {
        case .string(let stringValue):
            return stringValue
        case .stringConvertible(let stringConvertible):
            return "\(stringConvertible)"
        case .dictionary(let dictionary):
            var nested: [String: Any] = [:]
            for (key, value) in dictionary {
                nested[key] = jsonValue(of: value)
            }
            return nested
        case .array(let array):
            return array.map(jsonValue(of:))
        }
    }
}

private extension ISO8601DateFormatter {
    static let llmIOShared: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
