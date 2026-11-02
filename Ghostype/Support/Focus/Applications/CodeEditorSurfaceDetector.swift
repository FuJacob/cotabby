import Foundation

/// Tells a VS Code-family code editor apart from the other text fields in the same window.
///
/// VS Code, Cursor, Windsurf and other VS Code forks host the code editor, the Copilot/agent chat
/// input, the Source Control message box and the integrated terminal in one process with one bundle
/// identifier, so the per-app "Complete in code editors" switch needs a field-level signal. The chat
/// and commit inputs are Monaco editors too, so the focused node's own classes cannot separate them;
/// what does is where the node sits: the workbench wraps every editor tab's pane in an
/// `editor-instance` element, and chat/SCM inputs live outside it in their own panels.
///
/// `FocusSnapshotResolver` reads the focused element's `AXDOMClassList` (already read for the
/// integrated-terminal check), walks a bounded number of ancestors only when that element is a
/// Monaco input, and caches the verdict per focus session.
nonisolated enum CodeEditorSurfaceDetector {
    /// How far up the AX parent chain the resolver looks for the editor pane. The pane sits a few
    /// generic groups above Monaco's input node; the bound keeps a miss cheap.
    static let maximumAncestorDepth = 12

    /// Whether the focused element is Monaco's input node: the EditContext div of current VS Code
    /// (`native-edit-context`) or the hidden textarea of older builds (`inputarea`).
    static func isMonacoInput(domClassList: [String]) -> Bool {
        domClassList.contains { $0 == "native-edit-context" || $0 == "inputarea" }
    }

    /// Whether any ancestor's class list marks the workbench's editor pane.
    static func isInsideEditorPane(ancestorClassLists: [[String]]) -> Bool {
        ancestorClassLists.contains { $0.contains("editor-instance") }
    }
}
