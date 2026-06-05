import AppKit

/// File overview:
/// The pasteboard type Cotabby stamps on its own synthetic writes (the paste-insertion path) so the
/// clipboard history service can recognize and skip them instead of capturing the app's own
/// completions. Kept as a tiny shared constant so the inserter and the history service agree on the
/// marker without depending on each other.
enum SyntheticPasteboardMarker {
    /// An empty-data sentinel type. Its presence on a pasteboard item means "Cotabby wrote this".
    static let type = NSPasteboard.PasteboardType("com.cotabby.synthetic-write")
}
