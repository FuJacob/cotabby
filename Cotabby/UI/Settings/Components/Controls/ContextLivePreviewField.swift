import AppKit
import SwiftUI

/// File overview:
/// The Context pane's live-preview field, and the shared identity that lets the real pipeline drive it.
///
/// Cotabby never completes inside its own UI (`FocusTracker` blocks capture whenever Cotabby is the
/// focused app, so completions can never appear in the settings search field, the Extended Context
/// editor, menus, and so on). The live preview is the single sanctioned exception: it is a real,
/// native editable text view, tagged with `ContextLivePreview.accessibilityIdentifier`, and
/// `FocusTracker` lifts its self-capture rule for that one element only. Typing in it is therefore a
/// genuine end-to-end exercise of the production focus -> suggestion -> overlay -> insertion path, the
/// same one every other app gets.
///
/// Because the real overlay renders the gray suggestion at the caret and the real inserter commits it
/// on the accept key, this view renders nothing itself. That is the whole point of the redesign: the
/// previous in-app editor mirrored a SwiftUI binding into an `NSTextView` and reconciled a ghost run
/// inside the editable storage, and that reconciliation raced with live keystrokes and corrupted typed
/// text. Here the `NSTextView` owns its string outright and nothing reaches into it, so typing is fully
/// native.
enum ContextLivePreview {
    /// AX identifier on the preview field. `FocusTracker` keys on this exact value to allow
    /// self-capture for this element and nothing else in Cotabby's own windows. Wired into the focus
    /// pipeline in `CotabbyAppEnvironment`.
    static let accessibilityIdentifier = "com.cotabby.settings.context.live-preview"
}

/// A plain multi-line `NSTextView` whose only special behavior is carrying the sanctioned AX
/// identifier. No ghost logic, no binding round-trip: the running app completes in it like any field.
struct ContextLivePreviewField: NSViewRepresentable {
    private static let fontSize: CGFloat = 13
    private static let textInset = NSSize(width: 8, height: 8)

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.font = .monospacedSystemFont(ofSize: Self.fontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.isRichText = false
        // Keep typing literal so the preview shows exactly what the model receives: no curly quotes,
        // dash collapsing, autocorrect, or text replacement rewriting the user's characters.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = Self.textInset
        textView.drawsBackground = false

        // The identifier is the entire contract with `FocusTracker`: it is how the focus poller tells
        // this sanctioned field apart from every other element in Cotabby's own windows.
        textView.setAccessibilityIdentifier(ContextLivePreview.accessibilityIdentifier)

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
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Nothing to reconcile: the text view owns its content and the real pipeline owns the
        // suggestion. Intentionally empty.
    }
}
