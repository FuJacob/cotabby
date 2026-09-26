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
}

private extension FocusedInputPollingSignature {
    nonisolated struct FieldAnchor: Equatable {
        let roundedInputFrame: RoundedRect?
        let fallbackElementIdentifier: String?

        init(inputFrame: CGRect?, fallbackElementIdentifier: String) {
            roundedInputFrame = inputFrame.map { RoundedRect(rect: $0) }
            self.fallbackElementIdentifier = roundedInputFrame == nil ? fallbackElementIdentifier : nil
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
    }
}
