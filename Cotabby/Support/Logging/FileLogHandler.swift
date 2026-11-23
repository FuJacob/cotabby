import Foundation
import Logging

/// File overview:
/// A swift-log `LogHandler` that appends one JSON record per line to a file under
/// `~/Library/Logs/Cotabby/`. This is the on-disk sink an AI debugging agent can read
/// directly without copy-pasting from Console.app.
///
/// The handler is only installed when `-cotabby-debug` is passed at launch (see
/// `CotabbyLogger.bootstrap`). When the file grows past `sizeCapBytes` it is rotated: the
/// current file becomes `cotabby.jsonl.1` (overwriting any prior rotation) and a fresh empty
/// `cotabby.jsonl` is opened. Rotating instead of truncating keeps roughly the last 2× cap of
/// events on disk, so the *most recent* history survives at exactly the moment a debugger needs it.

/// Writer that owns one on-disk JSONL file handle. swift-log can call handlers from any thread,
/// so an `NSLock` serializes writes and the size check that may trigger a rotation.
///
/// `@unchecked Sendable`: the only mutable state is `handle` and `currentByteOffset`,
/// both guarded by `lock`. FileHandle itself is not Sendable so we cannot mark it cleanly.
nonisolated final class JSONLFileWriter: @unchecked Sendable {
    /// Main event stream (`cotabby.jsonl`).
    static let events = JSONLFileWriter(fileName: "cotabby.jsonl")
    /// Full prompts and completions (`llm-io.jsonl`). Records are larger per line, so the same
    /// cap holds fewer events, which is fine for a debug-only sink.
    static let llmIO = JSONLFileWriter(fileName: "llm-io.jsonl")

    /// Large enough for hours of debug output without ballooning disk.
    static let defaultSizeCapBytes: UInt64 = 10 * 1024 * 1024

    private let sizeCapBytes: UInt64
    private let lock = NSLock()
    private let logFileURL: URL?
    private var handle: FileHandle?
    private var currentByteOffset: UInt64 = 0

    /// `fileURL` overrides the default `~/Library/Logs/<bundle>/<fileName>` destination. Tests
    /// inject a temp-directory URL so rotation and write behavior can be exercised against a real
    /// file handle without touching the user's live logs.
    init(fileName: String, sizeCapBytes: UInt64 = JSONLFileWriter.defaultSizeCapBytes, fileURL: URL? = nil) {
        self.sizeCapBytes = sizeCapBytes
        self.logFileURL = fileURL ?? Self.makeLogFileURL(fileName: fileName)
        openHandle()
    }

    // The target's default MainActor isolation applies to this unannotated class, so without this
    // a deallocation routes through the back-deployment main-actor executor shim, which
    // double-frees in its StopLookupScope on macOS 26 (see InputSuppressionController). The shared
    // writers never deallocate in production; tests deallocate per-case writers constantly.
    nonisolated deinit {}

    /// Returns the on-disk path the handler writes to, if available. Useful for surfacing in
    /// settings and for tests.
    var fileURL: URL? { logFileURL }

    /// Appends one already-rendered line. Caller is responsible for the trailing newline.
    func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }

        // Rotating when *already over* the cap means the line that pushes us past gets stored
        // in the new file rather than the old one. That keeps the file's tail readable.
        // The rotation replaces `self.handle`, so we must read it AFTER the check — binding it
        // before would write the first post-cap line into a closed descriptor and drop it.
        if currentByteOffset >= sizeCapBytes {
            rotateLocked()
        }

        guard let handle else { return }

        do {
            try handle.write(contentsOf: data)
            currentByteOffset += UInt64(data.count)
        } catch {
            // Failing to write a debug log line must never disrupt the app. Swallow.
        }
    }

    /// One-step rotation: move the current file to `*.jsonl.1`, overwriting any prior rotation,
    /// then open a fresh empty file, so roughly the last 2× cap of history stays on disk.
    private func rotateLocked() {
        guard let logFileURL else { return }
        do {
            try handle?.close()
        } catch {
            // Closing a stale handle should not block re-opening a fresh one.
        }
        handle = nil
        // Only create a fresh empty file when the rotation actually displaced the old one — see
        // `rotateOnDisk`. Otherwise a silent `moveItem` failure (transient FS error, concurrent
        // external rewrite) would overwrite the still-present log with an empty file, destroying
        // exactly the history rotation was meant to preserve.
        let didRotate = rotateOnDisk(currentURL: logFileURL)
        if didRotate {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        openHandleLocked()
    }

    /// Returns `true` when the current file was successfully moved aside (or did not exist in the
    /// first place, which makes "create a fresh empty file" the correct next step). Returns
    /// `false` only when the source still occupies `currentURL` after the attempted move; the
    /// caller must then skip the `createFile` step so it does not destroy live log data.
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

    private static func makeLogFileURL(fileName: String) -> URL? {
        let fileManager = FileManager.default
        guard let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        let bundleName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Cotabby"
        let directory = libraryURL
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(bundleName, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }
}

/// Renders one log event as a single JSON line. Shared by both file handlers so the two sinks
/// cannot drift in field layout: metadata is flattened to top-level keys so it can be filtered
/// with `jq` without unpacking strings, and event metadata wins over handler metadata.
enum JSONLRecord {
    static func render(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        eventMetadata: Logging.Logger.Metadata?,
        handlerMetadata: Logging.Logger.Metadata,
        category: String
    ) -> String? {
        // swift-log's `LogEvent` does not carry an emission timestamp, so the handler must stamp
        // its own. Under sustained load this can lag the call site by a small number of ms; live
        // with that until swift-log surfaces emission time on the event itself.
        let timestamp = ISO8601DateFormatter.jsonlShared.string(from: Date())

        var record: [String: Any] = [
            "timestamp": timestamp,
            "level": "\(level)",
            "category": category,
            "message": "\(message)"
        ]

        if let eventMetadata {
            for (key, value) in eventMetadata {
                record[key] = jsonValue(of: value)
            }
        }
        for (key, value) in handlerMetadata where record[key] == nil {
            record[key] = jsonValue(of: value)
        }

        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json + "\n"
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

/// swift-log handler that serializes each event to one JSON object per line and forwards it
/// to the shared events writer.
struct FileLogHandler: LogHandler {
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level

    private let label: String
    private let writer: JSONLFileWriter

    /// `logLevel` defaults to `CotabbyDebugOptions.minimumLogLevel`. This sink is only installed
    /// under `-cotabby-debug`, where the floor is `.trace`, so it captures everything by default —
    /// but sourcing the level from the same place keeps it honest if the floor is overridden via
    /// `COTABBY_LOG_LEVEL`.
    init(
        label: String,
        writer: JSONLFileWriter = .events,
        logLevel: Logging.Logger.Level = CotabbyDebugOptions.minimumLogLevel
    ) {
        self.label = label
        self.writer = writer
        self.logLevel = logLevel
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: borrowing Logging.LogEvent) {
        guard let line = JSONLRecord.render(
            level: event.level,
            message: event.message,
            eventMetadata: event.metadata,
            handlerMetadata: metadata,
            category: CotabbyLogger.category(forLabel: label)
        ) else {
            return
        }
        writer.write(line)
    }
}

private extension ISO8601DateFormatter {
    /// Shared formatter avoids allocating a new one per log line. ISO8601 is thread-safe.
    static let jsonlShared: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
