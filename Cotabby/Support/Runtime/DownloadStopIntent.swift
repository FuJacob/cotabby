import Foundation

/// What the user asked a running model download to do. One request is in force at a time and
/// cancel outranks pause: a cancelled transfer deletes its partial data, so letting a later pause
/// win would publish a resumable state for bytes that are about to be removed.
nonisolated enum DownloadStopIntent: Equatable, Sendable {
    case pause
    case cancel

    /// The intent in force after `requested` arrives on top of `current`.
    static func merging(_ current: DownloadStopIntent?, with requested: DownloadStopIntent) -> DownloadStopIntent {
        current == .cancel ? .cancel : requested
    }
}

/// How a download reports that it stopped because the user asked, as opposed to failing. The
/// session delegate throws `.paused`; the manager throws either case when the request landed
/// before a session opened.
nonisolated enum DownloadInterruption: Error, Equatable {
    /// `resumeData` is URLSession's opaque resume blob when it produced one. It is nil when the
    /// pause landed before a session opened, and the manager then keeps the data it already had.
    case paused(resumeData: Data?)
    case cancelled
}
