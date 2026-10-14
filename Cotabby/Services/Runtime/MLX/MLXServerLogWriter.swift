import Foundation

/// File overview:
/// Appends everything `mlx_lm.server` writes to stderr to `~/Library/Logs/<CFBundleName>/mlx-server.log`,
/// so the cause of a server failure survives the in-memory tail. It exists because a generator
/// that died once could not be diagnosed afterwards: the only copy of the traceback was a 20-line
/// buffer in the app. Each server start opens with a header line that says which pid, model and
/// port the lines below belong to.
///
/// Debug-only, like the JSONL sinks: `MLXLiveProcessLauncher` uses the shared writer only when the
/// app runs with `-cotabby-debug` (`CotabbyDebugOptions.isEnabled`). In a normal run the server's
/// stderr stays in memory and nothing is written here.
///
/// Owned by `MLXLiveProcessLauncher` (a single shared writer). `write` is called from the pipe's
/// readability handler on a background thread, so the handle is guarded by a lock and nothing here
/// touches the main actor. Rotation is the same one-step scheme as `LLMIOFileWriter`.
nonisolated final class MLXServerLogWriter: @unchecked Sendable {
    static let shared = MLXServerLogWriter()
    static let defaultSizeCapBytes: UInt64 = 2 * 1024 * 1024

    private let lock = NSLock()
    private let fileURL: URL?
    private let sizeCapBytes: UInt64
    private var handle: FileHandle?
    private var currentByteOffset: UInt64 = 0

    /// Tests inject a temp-directory URL and a small cap.
    init(fileURL: URL? = nil, sizeCapBytes: UInt64 = MLXServerLogWriter.defaultSizeCapBytes) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.sizeCapBytes = sizeCapBytes
    }

    // Same note as `LLMIOFileWriter`: the target's default MainActor isolation would route
    // deallocation through a back-deployment shim that has crashed on macOS 26.
    nonisolated deinit {}

    func writeHeader(pid: Int32, model: String, port: Int, date: Date = Date()) {
        let stamp = ISO8601DateFormatter().string(from: date)
        write(Data("=== \(stamp) server pid=\(pid) model=\(model) port=\(port) ===\n".utf8))
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if currentByteOffset >= sizeCapBytes { rotateLocked() }
        if handle == nil { openLocked() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            currentByteOffset += UInt64(data.count)
        } catch {
            // Diagnostics only: a full disk must never disturb the server or the app.
        }
    }

    /// Renames the current file to `mlx-server.log.1` (replacing an older one) and starts fresh.
    private func rotateLocked() {
        guard let fileURL else { return }
        try? handle?.close()
        handle = nil
        let rotated = fileURL.appendingPathExtension("1")
        let manager = FileManager.default
        try? manager.removeItem(at: rotated)
        try? manager.moveItem(at: fileURL, to: rotated)
        openLocked()
    }

    private func openLocked() {
        guard let fileURL else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: fileURL.path) { manager.createFile(atPath: fileURL.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: fileURL)
        currentByteOffset = (try? handle?.seekToEnd()) ?? 0
    }

    /// `~/Library/Logs/<CFBundleName>/mlx-server.log`, the folder `FileLogHandler` and
    /// `LLMIOFileWriter` use (their helpers are private, so the same lookup is repeated here).
    private static func defaultFileURL() -> URL? {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        let bundleName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Cotabby"
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(bundleName, isDirectory: true)
            .appendingPathComponent("mlx-server.log")
    }
}
