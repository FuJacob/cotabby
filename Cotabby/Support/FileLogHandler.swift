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
/// `cotabby.jsonl` is opened. The previous truncate-to-zero behavior threw away the *most
/// recent* history at exactly the moment a debugger most needed it; one-step rotation keeps
/// roughly the last 2× cap of events on disk.

/// Shared writer that owns the on-disk file handle. swift-log can call handlers from any
/// thread, so an `NSLock` serializes writes and the size check that may trigger a wipe.
///
/// `@unchecked Sendable`: the only mutable state is `handle` and `currentByteOffset`,
/// both guarded by `lock`. FileHandle itself is not Sendable so we cannot mark it cleanly.
final class FileLogWriter: @unchecked Sendable {
    static let shared = FileLogWriter()

    /// Default cap of 10 MB. Large enough for hours of debug output without ballooning disk.
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
        if currentByteOffset >= effectiveCap {
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

    /// Test-only hook to force a rotation.
    func wipeForTesting() {
        lock.lock()
        defer { lock.unlock() }
        rotateLocked()
    }

    private func rotateLocked() {
        guard let logFileURL else { return }
        do {
            try handle?.close()
        } catch {
            // Closing a stale handle should not block re-opening a fresh one.
        }
        handle = nil
        // One-step rotation: move the current file to `*.jsonl.1`, overwriting any prior rotation,
        // then open a fresh empty file. Keeps the most recent ~cap of history on disk that the
        // previous truncate-to-zero behavior was dropping at the exact moment it was useful.
        // Only create a fresh empty file when the rotation actually displaced the old one — see
        // `rotateOnDisk`. Otherwise we would silently overwrite the still-present log with an
        // empty file, destroying exactly the history rotation was meant to preserve.
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
        return directory.appendingPathComponent("cotabby.jsonl")
    }
}

/// swift-log handler that serializes each event to one JSON object per line and forwards it
/// to a shared `FileLogWriter`. Metadata fields (e.g. `prompt`, `raw_output`) are emitted as
/// top-level keys so they can be filtered with `jq` without unpacking strings.
struct FileLogHandler: LogHandler {
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .trace

    private let label: String
    private let writer: FileLogWriter

    init(label: String, writer: FileLogWriter = .shared) {
        self.label = label
        self.writer = writer
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: borrowing Logging.LogEvent) {
        let category = Self.category(from: label)
        // swift-log's `LogEvent` does not carry an emission timestamp, so the handler must stamp
        // its own. Under sustained load this can lag the call site by a small number of ms; live
        // with that until swift-log surfaces emission time on the event itself.
        let timestamp = ISO8601DateFormatter.shared.string(from: Date())

        var record: [String: Any] = [
            "timestamp": timestamp,
            "level": "\(event.level)",
            "category": category,
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

    /// `com.cotabby.runtime` → `runtime`. Matches `OSLogHandler`'s category convention so the
    /// JSON `category` field lines up with what Console.app shows.
    private static func category(from label: String) -> String {
        let parts = label.split(separator: ".", maxSplits: 2)
        return parts.count > 2 ? String(parts[2]) : label
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
    /// Shared formatter avoids allocating a new one per log line. ISO8601 is thread-safe.
    static let shared: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
