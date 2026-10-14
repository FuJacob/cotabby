import Foundation

/// File overview:
/// Cuts the selected text out of the bounded text window `FocusSnapshotResolver` reads. Pure so the
/// clamping (AX ranges can run past a value that changed between two reads) and composed-character
/// handling are pinned by tests.
nonisolated enum FocusSelectionText {
    /// The text under `windowSelection` in `windowText`, clamped to the text and widened to whole
    /// composed characters so a range that splits an emoji never yields half of it.
    static func extract(windowText: String, windowSelection: NSRange) -> String {
        let text = windowText as NSString
        let location = min(max(windowSelection.location, 0), text.length)
        let end = min(location + max(windowSelection.length, 0), text.length)
        guard end > location else { return "" }
        let composed = text.rangeOfComposedCharacterSequences(for: NSRange(location: location, length: end - location))
        return text.substring(with: composed)
    }
}
