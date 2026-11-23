import CoreGraphics

/// File overview:
/// Everything the macro preview knows about one open `/query` capture. The controller holds this as
/// an optional: `nil` is idle, a value is capturing, so the anchor, query and evaluated result are
/// always created and dropped together.
///
/// The trigger machine still owns the keystroke-level lifecycle; this is the payload that depends
/// on Accessibility (where the capture lives) and on the macro engine (what it evaluates to).
struct MacroCaptureSession: Equatable {
    /// The focus sequence of the field the capture opened in. A snapshot carrying a different value
    /// means the typed `/query` run is no longer under the caret.
    let focusChangeSequence: UInt64
    /// Latest caret position, which the preview follows as the query grows.
    var caretRect: CGRect
    private(set) var query = ""
    /// What the current query evaluates to, or `nil` while it is not (yet) a valid macro.
    private(set) var result: MacroResult?

    init(focusChangeSequence: UInt64, caretRect: CGRect) {
        self.focusChangeSequence = focusChangeSequence
        self.caretRect = caretRect
    }

    /// Query and result always change together: a result is only ever the evaluation of `query`.
    mutating func setResult(_ result: MacroResult?, for query: String) {
        self.query = query
        self.result = result
    }

    /// UTF-16 length of the typed run a commit replaces: the `/` sigil plus the tracked query. Exact
    /// by construction, so text after the run is never touched.
    var typedRunUTF16Count: Int {
        1 + query.utf16.count
    }
}
