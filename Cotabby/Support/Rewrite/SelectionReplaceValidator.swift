import Foundation

/// File overview:
/// The last check before a rewrite replaces text. Between opening the popup and pressing Replace the
/// user may click elsewhere, the host may redraw the field, or focus may move. Typing over whatever
/// is selected then would overwrite the wrong text, so Replace proceeds only when the same field
/// still holds the same selected text at the same place: the same host range, and the same text
/// right around it. The surrounding text is what tells two copies of one phrase apart in hosts
/// that report no host range (Chromium contenteditables). Matching text at a different place, such
/// as a repeated word elsewhere in the field, is not the user's selection and is copied instead. A same-field caret with no selection (focus came back from the
/// popup's instruction box) may be repaired by restoring the original range first; anything else
/// copies the result to the clipboard.

/// The selection a rewrite was started for.
nonisolated struct SelectionRewriteTarget: Equatable, Sendable {
    let fieldKey: String
    let selectedText: String
    let hostSelection: NSRange?
    /// The text just before and just after the selection, which places it when `hostSelection` is
    /// nil. Short, so an edit far away in a long field does not count as moving the selection.
    let precedingContext: String
    let trailingContext: String
    let bundleIdentifier: String
    let processIdentifier: Int32

    static let contextLength = 32

    init(snapshot: FocusedInputSnapshot) {
        fieldKey = Self.fieldKey(for: snapshot)
        selectedText = snapshot.selectedText
        hostSelection = snapshot.hostSelection
        precedingContext = String(snapshot.precedingText.suffix(Self.contextLength))
        trailingContext = String(snapshot.trailingText.prefix(Self.contextLength))
        bundleIdentifier = snapshot.bundleIdentifier
        processIdentifier = snapshot.processIdentifier
    }

    /// Stable while a field resizes, like `focusedInputIdentityKey`, and readable as text in logs.
    static func fieldKey(for snapshot: FocusedInputSnapshot) -> String {
        "\(snapshot.bundleIdentifier)|\(snapshot.processIdentifier)|\(snapshot.elementIdentifier)"
    }
}

nonisolated enum SelectionReplaceValidator {
    enum Outcome: Equatable {
        case replace
        case restoreSelectionThenReplace
        case copyInstead(String)
    }

    static func outcome(target: SelectionRewriteTarget, current: FocusedInputSnapshot?) -> Outcome {
        guard let current, SelectionRewriteTarget.fieldKey(for: current) == target.fieldKey else {
            return .copyInstead("The field is no longer focused — copied to clipboard.")
        }
        guard current.selectedText == target.selectedText else {
            if current.selectedText.isEmpty, target.hostSelection != nil { return .restoreSelectionThenReplace }
            return .copyInstead("Selection changed — copied to clipboard.")
        }
        // Same text in the same field can still sit at another place. With a host range on both sides
        // the range decides; without one, the text around the selection must match instead, so a
        // second copy of the phrase elsewhere is never taken for the first.
        if let currentRange = current.hostSelection, let targetRange = target.hostSelection {
            if currentRange != targetRange { return .copyInstead("Selection changed — copied to clipboard.") }
        } else if SelectionRewriteTarget(snapshot: current).precedingContext != target.precedingContext
            || SelectionRewriteTarget(snapshot: current).trailingContext != target.trailingContext {
            return .copyInstead("Selection changed — copied to clipboard.")
        }
        return .replace
    }
}
