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

/// How a download backend reports that it stopped because the user asked, as opposed to failing.
/// Both backends throw this one type so the manager never has to know which of them was running.
nonisolated enum DownloadInterruption: Error, Equatable {
    /// `resumeData` is URLSession's opaque resume blob when it produced one. aria2 always passes
    /// nil because its resume state lives in the `.aria2` control file inside the staging directory.
    case paused(resumeData: Data?)
    case cancelled
}
