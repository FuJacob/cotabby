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
    let fieldPlaceholder: String?

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
        guard bundleIdentifier == previous.bundleIdentifier, processIdentifier == previous.processIdentifier,
              role == previous.role, subrole == previous.subrole, windowTitle == previous.windowTitle,
              focusedURLString == previous.focusedURLString, fieldPlaceholder == previous.fieldPlaceholder
        else { return false }
        return fieldAnchor.continues(previous.fieldAnchor)
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
