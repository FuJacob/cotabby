import AppKit
import SwiftUI

/// File overview:
/// A focused multi-line text editor for the Context pane's live preview. It renders a model-provided
/// completion as gray "ghost" text immediately after the user's caret, exactly like Cotabby's real
/// overlay, and commits it on Tab. SwiftUI's `TextEditor` cannot place a styled continuation at the
/// caret, so this wraps `NSTextView` directly.
///
/// Core invariant that keeps the AppKit bridge simple:
/// the ghost is only ever a trailing gray run at the very end of the storage, shown only when the
/// caret is an empty selection at end-of-text (the natural "continue my sentence" case). Because the
/// ghost is always the tail:
///   - stripping it before reporting the user's text is one range delete,
///   - a user edit (insert / delete / paste) at the caret never lands inside it, so we can strip it
///     uniformly in `textDidChange` instead of intercepting every edit entry point.
/// The two cases that *would* touch the ghost are handled explicitly: forward-delete dismisses it,
/// and a caret move off the boundary dismisses it.
///
/// The ghost never enters the `text` binding. `text` is always the clean user string; `ghost` is a
/// display-only suffix owned by `LivePreviewModel`.
struct InlineCompletionEditor: NSViewRepresentable {
    @Binding var text: String
    /// Display-only completion suffix. Empty string means "no ghost".
    let ghost: String
    /// Commit the ghost into the user's text (Tab). The model moves `ghost` into `text`.
    let onAccept: () -> Void
    /// Discard the current ghost (Esc, forward-delete over it, or caret moved away from the end).
    let onDismiss: () -> Void

    static let fontSize: CGFloat = 13
    private static let textInset = NSSize(width: 8, height: 8)

    func makeNSView(context: Context) -> NSScrollView {
        let textView = InlineCompletionTextView()
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: Self.fontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.typingAttributes = context.coordinator.userAttributes()
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = Self.textInset
        textView.drawsBackground = false

        // Standard incantation for a wrapping, vertically-growing text view inside a scroll view.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        context.coordinator.textView = textView
        textView.string = text
        context.coordinator.reconcile(text: text, ghost: ghost)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Keep the action closures current so Tab/Esc route to the latest model callbacks.
        context.coordinator.parent = self
        context.coordinator.reconcile(text: text, ghost: ghost)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Bridges `NSTextView` edits and the SwiftUI bindings, and owns the trailing-ghost bookkeeping.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineCompletionEditor
        weak var textView: InlineCompletionTextView?

        /// UTF-16 length of the gray ghost run currently displayed at the tail, or 0 when none.
        private var ghostLength = 0
        /// True while we mutate storage/selection ourselves, so delegate callbacks ignore our own
        /// edits instead of treating them as user input.
        private var isProgrammaticEdit = false

        init(parent: InlineCompletionEditor) {
            self.parent = parent
        }

        var hasGhost: Bool { ghostLength > 0 }

        /// The clean user string = full storage minus the trailing ghost run.
        private var userText: String {
            guard let textView else { return parent.text }
            let full = textView.string as NSString
            let userLength = max(0, full.length - ghostLength)
            return full.substring(to: userLength)
        }

        // MARK: Reconciliation (driven by updateNSView)

        /// Make the view reflect (`text`, `ghost`). User text is reconciled first so that on accept —
        /// where `text` grows and `ghost` clears in the same update — the stale gray run is removed by
        /// the ghost pass afterward rather than being double-counted.
        func reconcile(text: String, ghost: String) {
            if userText != text {
                replaceUserText(text)
            }
            applyGhost(ghost)
        }

        /// Replace just the user portion (used when the model changed `text`, e.g. after accept).
        private func replaceUserText(_ newText: String) {
            guard let textView, let storage = textView.textStorage else { return }
            let full = textView.string as NSString
            let userLength = max(0, full.length - ghostLength)
            withProgrammaticEdit(on: textView) {
                storage.replaceCharacters(
                    in: NSRange(location: 0, length: userLength),
                    with: NSAttributedString(string: newText, attributes: userAttributes())
                )
                let newUserLength = (newText as NSString).length
                textView.setSelectedRange(NSRange(location: newUserLength, length: 0))
            }
        }

        /// Make the trailing gray run equal `ghost`, inserting/removing as needed. No-ops when the
        /// displayed ghost already matches.
        private func applyGhost(_ ghost: String) {
            guard let textView, let storage = textView.textStorage else { return }
            let full = textView.string as NSString
            let userLength = max(0, full.length - ghostLength)
            let currentGhost = ghostLength > 0 ? full.substring(from: userLength) : ""
            guard currentGhost != ghost else { return }

            withProgrammaticEdit(on: textView) {
                if ghostLength > 0 {
                    storage.deleteCharacters(in: NSRange(location: userLength, length: ghostLength))
                }
                if !ghost.isEmpty {
                    storage.insert(
                        NSAttributedString(string: ghost, attributes: ghostAttributes()),
                        at: userLength
                    )
                }
                // Keep the caret at the user/ghost boundary so typing continues before the ghost.
                textView.setSelectedRange(NSRange(location: userLength, length: 0))
            }
            ghostLength = (ghost as NSString).length
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticEdit, let textView else { return }
            // A user edit happened with the ghost (if any) still trailing. Strip the known tail so the
            // binding only ever sees clean user text. Safe for insert/delete/paste because the caret
            // sits at the user/ghost boundary, so the edit never lands inside the trailing run.
            if ghostLength > 0 {
                stripGhost()
            }
            let newText = textView.string
            if parent.text != newText {
                parent.text = newText
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isProgrammaticEdit, ghostLength > 0, let textView else { return }
            let userLength = max(0, (textView.string as NSString).length - ghostLength)
            let selection = textView.selectedRange()
            let caretAtBoundary = selection.length == 0 && selection.location == userLength
            guard !caretAtBoundary else { return }
            // The caret left the ghost boundary. This also fires transiently while the system applies
            // a user insertion (the caret hops past the inserted char before `textDidChange` strips
            // the ghost). Defer to the next main-actor tick and re-check so we only dismiss on a
            // genuine caret move (a click or arrow key), not on typing — by then a real edit will have
            // reset `ghostLength` to 0 and this no-ops.
            Task { @MainActor [weak self] in
                guard let self, self.ghostLength > 0, let textView = self.textView else { return }
                let userLength = max(0, (textView.string as NSString).length - self.ghostLength)
                let selection = textView.selectedRange()
                let caretAtBoundary = selection.length == 0 && selection.location == userLength
                if !caretAtBoundary {
                    self.parent.onDismiss()
                }
            }
        }

        // MARK: Commands forwarded from the text view

        /// Tab. Commit the ghost when present; otherwise move focus rather than inserting a literal tab.
        func handleTab() {
            if ghostLength > 0 {
                parent.onAccept()
            } else {
                textView?.window?.selectNextKeyView(nil)
            }
        }

        /// Esc. Drop the current ghost.
        func handleEscape() {
            if ghostLength > 0 {
                parent.onDismiss()
            }
        }

        /// Forward-delete is the one edit that would land on the ghost's first character, so route it
        /// to a dismiss instead of letting it eat the suggestion. Returns true when it consumed the key.
        func handleForwardDeleteIfGhostPresent() -> Bool {
            guard ghostLength > 0 else { return false }
            parent.onDismiss()
            return true
        }

        private func stripGhost() {
            guard let textView, let storage = textView.textStorage, ghostLength > 0 else { return }
            let userLength = max(0, (textView.string as NSString).length - ghostLength)
            withProgrammaticEdit(on: textView) {
                storage.deleteCharacters(in: NSRange(location: userLength, length: ghostLength))
            }
            ghostLength = 0
        }

        /// Runs `body` as a non-undoable programmatic mutation: delegate callbacks ignore it and the
        /// user's undo stack stays operating on clean text only.
        private func withProgrammaticEdit(on textView: NSTextView, _ body: () -> Void) {
            isProgrammaticEdit = true
            textView.undoManager?.disableUndoRegistration()
            textView.textStorage?.beginEditing()
            body()
            textView.textStorage?.endEditing()
            textView.undoManager?.enableUndoRegistration()
            textView.typingAttributes = userAttributes()
            isProgrammaticEdit = false
        }

        func userAttributes() -> [NSAttributedString.Key: Any] {
            [
                .font: NSFont.monospacedSystemFont(ofSize: InlineCompletionEditor.fontSize, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
        }

        private func ghostAttributes() -> [NSAttributedString.Key: Any] {
            [
                .font: NSFont.monospacedSystemFont(ofSize: InlineCompletionEditor.fontSize, weight: .regular),
                .foregroundColor: NSColor.inlineGhostText
            ]
        }
    }
}

/// `NSTextView` subclass that routes Tab / Esc / forward-delete to the inline-completion coordinator.
/// Kept as a thin shell: all state and bookkeeping live on the coordinator.
final class InlineCompletionTextView: NSTextView {
    weak var coordinator: InlineCompletionEditor.Coordinator?

    override func insertTab(_ sender: Any?) {
        coordinator?.handleTab()
    }

    override func cancelOperation(_ sender: Any?) {
        coordinator?.handleEscape()
    }

    override func deleteForward(_ sender: Any?) {
        if coordinator?.handleForwardDeleteIfGhostPresent() == true {
            return
        }
        super.deleteForward(sender)
    }
}

private extension NSColor {
    /// Matches `OverlayController`'s inline ghost gray so the sandbox preview reads like the real
    /// product: lighter in dark mode, darker in light mode.
    static let inlineGhostText = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? NSColor(white: 0.65, alpha: 1) : NSColor(white: 0.45, alpha: 1)
    }
}
