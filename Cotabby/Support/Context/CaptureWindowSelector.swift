import CoreGraphics

/// Pure choice of the window to capture for the focused field.
///
/// ScreenCaptureKit lists an app's windows in no documented order, and with several documents
/// open more than one can report itself active. Taking the first such window captured a background
/// document of the same app: its text entered the prompt, and the change from the focused
/// window's text read as navigation and retired the visible suggestion. The focused field's window
/// is the front-most one under its caret, in the window server's front-to-back order.
///
/// Kept apart from `WindowScreenshotService` so the choice is testable without ScreenCaptureKit.
nonisolated enum CaptureWindowSelector {
    struct Candidate: Equatable {
        let id: CGWindowID
        /// Global display points, top-left origin (ScreenCaptureKit's space).
        let frame: CGRect
        let isActive: Bool
    }

    /// - Parameters:
    ///   - candidates: The focused app's on-screen windows.
    ///   - caret: The caret's centre in the same space as the frames.
    ///   - frontToBack: Window numbers front-most first. Windows missing from it rank behind all
    ///     listed ones and keep their list order, so an empty order falls back to list order.
    static func select(_ candidates: [Candidate], caret: CGPoint, frontToBack: [CGWindowID]) -> CGWindowID? {
        let rank = Dictionary(frontToBack.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        func frontMost(_ windows: [Candidate]) -> Candidate? {
            windows.min { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
        }
        let underCaret = candidates.filter { $0.frame.contains(caret) }
        return (frontMost(underCaret) ?? frontMost(candidates.filter(\.isActive)) ?? frontMost(candidates))?.id
    }
}
