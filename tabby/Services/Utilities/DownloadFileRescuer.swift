import Foundation

/// File overview:
/// Encapsulates the CFNetwork temp-file rescue that `ModelDownloadSessionDelegate`
/// needs to perform inside `urlSession(_:downloadTask:didFinishDownloadingTo:)`.
/// The logic is extracted from the delegate so the race-sensitive part is
/// covered by unit tests instead of only by real downloads.
///
/// Why this is its own type:
/// URLSession's `URLSessionDownloadTask` is painful to construct in a unit
/// test without mocking the whole networking stack. Separating the file-move
/// decision from the delegate callback means the decision can be tested
/// with just a real `FileManager` and a pair of real file URLs.
enum DownloadFileRescuer {
    /// Moves the URLSession-provided temp file at `location` to a holding URL
    /// we own, synchronously, within the single delegate callback where the
    /// source file is still valid.
    ///
    /// Why this must be synchronous:
    /// URLSession's contract for `didFinishDownloadingTo` is that `location`
    /// is valid only for the duration of that one callback. CFNetwork reclaims
    /// the file the moment the callback returns. Any `DispatchQueue.async`,
    /// `Task {}`, or continuation hop between receiving `location` and moving
    /// it would race against CFNetwork's cleanup — which is exactly the bug
    /// this rescue pathway was introduced to fix (see PR #31 / issue #30).
    static func rescue(
        temporaryFileAt location: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let holdingURL = fileManager.temporaryDirectory
            .appendingPathComponent("tabby-download-\(UUID().uuidString)", isDirectory: false)
        try fileManager.moveItem(at: location, to: holdingURL)
        return holdingURL
    }

    /// Best-effort cleanup of a previously-rescued holding file. Called when
    /// the download ultimately fails after `rescue` already succeeded — either
    /// a transport error arrived or a stashed rescue error needs surfacing.
    ///
    /// Errors from the removal are intentionally swallowed. By the time we're
    /// in cleanup, the caller has a real failure to report; a secondary file-
    /// system error here would just obscure the root cause. A leaked temp
    /// file in this path is harmless — macOS reaps `temporaryDirectory` on
    /// reboot and normal temp-sweep cycles.
    static func cleanup(
        holdingFileAt url: URL,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: url)
    }
}
