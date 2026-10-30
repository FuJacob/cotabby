import CoreGraphics
import Foundation

/// Stable-enough identity for one focused input as observed by polling.
///
/// Text, selection, and caret position are deliberately excluded. Those can change inside the same
/// field and should not restart the visual-context session. The input frame is preferred over the
/// AX element id because AX identifiers are derived from Core Foundation object identity, which can
/// be recycled by macOS. Fresh surface facts distinguish tabs/conversations that reuse the same
/// composer geometry. This pure value is owned by FocusTracker for one poll comparison; it excludes
/// text and selection so ordinary typing does not become a navigation event.
nonisolated struct FocusedInputPollingSignature: Equatable {
    let bundleIdentifier: String
    let processIdentifier: Int32
    let role: String
    let subrole: String?
    private let fieldAnchor: FieldAnchor
    let windowTitle: String?
    let focusedURLString: String?
    /// The placeholder this field last showed. A fresh signature holds this poll's read; the one
    /// FocusTracker remembers after a continuing poll (`continuation(of:)`) keeps the session's last
    /// shown placeholder while the host hides it, so a field cleared later can be recognized.
    private(set) var fieldPlaceholder: String?

    init(context: FocusedInputSnapshot) {
        bundleIdentifier = context.bundleIdentifier
        processIdentifier = context.processIdentifier
        role = context.role
        subrole = context.subrole
        windowTitle = context.windowTitle
        focusedURLString = context.focusedURLString
        fieldPlaceholder = context.fieldPlaceholder
        fieldAnchor = FieldAnchor(
            inputFrame: context.inputFrameRect,
            fallbackElementIdentifier: context.elementIdentifier
        )
    }

    /// True when this poll still observes the field `previous` described. Every identity fact must
    /// match, but the frame may resize in place: a chat composer grows when a line wraps, keeping
    /// its left edge, width, and either its top or bottom edge. Treating that as navigation would
    /// start a new writing session and discard the visible suggestion on every wrap. Two distinct
    /// fields stacked at the same x and width still differ at both edges.
    func continuesField(of previous: FocusedInputPollingSignature) -> Bool {
        continuation(of: previous) != nil
    }

    /// The signature FocusTracker should remember when this poll continues `previous`'s field, or
    /// nil when it observes a different field. The returned value tracks this poll's frame (so later
    /// growth is compared with the current edges) and the session's last shown placeholder.
    ///
    /// The placeholder is the one fact a host changes in response to the text itself: it is shown
    /// only while the field is empty. Chromium composers (the Claude desktop composer reports
    /// "Type / for commands.") drop `AXPlaceholderValue` a poll or two after the first typed
    /// character and restore it when the field is cleared. Comparing it strictly turned each of those
    /// moments into navigation: a new focus session, a restarted screenshot/OCR capture, and a
    /// cancelled generation. So a placeholder that disappears is never evidence, and one that
    /// appears is evidence only when it is not the placeholder this session already showed. Another
    /// conversation that reuses the composer with a different placeholder still breaks continuity.
    func continuation(of previous: FocusedInputPollingSignature) -> FocusedInputPollingSignature? {
        guard bundleIdentifier == previous.bundleIdentifier, processIdentifier == previous.processIdentifier,
              role == previous.role, subrole == previous.subrole, windowTitle == previous.windowTitle,
              focusedURLString == previous.focusedURLString,
              fieldPlaceholder == nil || fieldPlaceholder == previous.fieldPlaceholder,
              fieldAnchor.continues(previous.fieldAnchor)
        else { return nil }
        var remembered = self
        remembered.fieldPlaceholder = fieldPlaceholder ?? previous.fieldPlaceholder
        return remembered
    }

    /// Names of the identity facts that differ from `previous`, for logging why a poll opened a new
    /// focus session. Names only: titles, URLs, and placeholders can identify what the user is doing.
    func changedFacts(since previous: FocusedInputPollingSignature) -> [String] {
        var facts: [String] = []
        if bundleIdentifier != previous.bundleIdentifier || processIdentifier != previous.processIdentifier {
            facts.append("app")
        }
        if role != previous.role || subrole != previous.subrole { facts.append("role") }
        if windowTitle != previous.windowTitle { facts.append("title") }
        if focusedURLString != previous.focusedURLString { facts.append("url") }
        if fieldPlaceholder != nil, fieldPlaceholder != previous.fieldPlaceholder { facts.append("placeholder") }
        if !fieldAnchor.continues(previous.fieldAnchor) { facts.append("frame") }
        return facts
    }
}

private extension FocusedInputPollingSignature {
    nonisolated struct FieldAnchor: Equatable {
        let roundedInputFrame: RoundedRect?
        let fallbackElementIdentifier: String?

        init(inputFrame: CGRect?, fallbackElementIdentifier: String) {
            roundedInputFrame = inputFrame.map { RoundedRect(rect: $0) }
            self.fallbackElementIdentifier = roundedInputFrame == nil ? fallbackElementIdentifier : nil
        }

        func continues(_ previous: FieldAnchor) -> Bool {
            guard let frame = roundedInputFrame, let previousFrame = previous.roundedInputFrame else {
                return self == previous
            }
            return frame.minX == previousFrame.minX && frame.width == previousFrame.width
                && (frame.minY == previousFrame.minY || frame.maxY == previousFrame.maxY)
        }
    }

    nonisolated struct RoundedRect: Equatable {
        let minX: Int
        let minY: Int
        let width: Int
        let height: Int

        init(rect: CGRect) {
            minX = Int(rect.minX.rounded())
            minY = Int(rect.minY.rounded())
            width = Int(rect.width.rounded())
            height = Int(rect.height.rounded())
        }

        var maxY: Int { minY + height }
    }
}
