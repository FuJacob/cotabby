import Foundation

/// File overview:
/// The last check before a rewrite replaces text. Between opening the popup and pressing Replace the
/// user may click elsewhere, the host may redraw the field, or focus may move. Typing over whatever
/// is selected then would overwrite the wrong text, so Replace proceeds only when the same field
/// still holds the same selected text at the same place (the same host range). Matching text at a
/// different place, such as a repeated word elsewhere in the field, is not the user's selection and
/// is copied instead. A same-field caret with no selection (focus came back from the
/// popup's instruction box) may be repaired by restoring the original range first; anything else
/// copies the result to the clipboard.

/// The selection a rewrite was started for.
nonisolated struct SelectionRewriteTarget: Equatable, Sendable {
    let fieldKey: String
    let selectedText: String
    let hostSelection: NSRange?
    let bundleIdentifier: String
    let processIdentifier: Int32

    init(snapshot: FocusedInputSnapshot) {
        fieldKey = Self.fieldKey(for: snapshot)
        selectedText = snapshot.selectedText
        hostSelection = snapshot.hostSelection
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
        // Same text in the same field can still sit at another place. Compare the host range only when
        // both sides have one; without a range there is nothing to compare, so the text alone decides.
        if let currentRange = current.hostSelection, let targetRange = target.hostSelection, currentRange != targetRange {
            return .copyInstead("Selection changed — copied to clipboard.")
        }
        return .replace
    }
}
