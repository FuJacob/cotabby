import CoreGraphics
import Foundation

/// File overview:
/// Decides the horizontal band wrapped ghost rows may occupy, from what the host actually
/// exposed. Pure so the branches are unit-testable without an overlay panel.
///
/// Left edge: the host's measured line box when known (that is where the host starts its own
/// next line), else the element's inner edge. Right edge: the element's own frame minus the same
/// inset the left edge showed, because TextKit and web hosts pad both sides of their text
/// container equally. Only the element's real frame is trusted: the widened input frame used for
/// card placement would let a row run past the host's edge (measured live in TextEdit: a 420pt
/// window produced a 561pt band and the ghost's first row ran off the window).
enum GhostWrapBandPolicy {
    struct Input {
        let caretRect: CGRect
        /// The element's own frame, unwidened (see `FocusedInputSnapshot.elementFrameRect`).
        let elementFrame: CGRect?
        /// The widened frame used for card placement; only a last resort here.
        let inputFrame: CGRect?
        /// Left edge of the host's measured caret-line box, when it exposed one.
        let lineLeft: CGFloat?
        /// The screen's visible frame; rows never leave it.
        let screenVisibleFrame: CGRect
    }

    /// Horizontal padding assumed between a field's frame and its text when no line box says otherwise.
    static let defaultContentInset: CGFloat = 4
    /// A line box this far inside its element is still believed to be that element's padding.
    static let maximumBelievableInset: CGFloat = 60
    static let screenMargin: CGFloat = 8
    /// Frames narrower than this are not text containers worth wrapping inside.
    static let minimumContainerWidth: CGFloat = 40

    static func band(_ input: Input) -> ClosedRange<CGFloat> {
        let screenLeft = input.screenVisibleFrame.minX + screenMargin
        let screenRight = input.screenVisibleFrame.maxX - screenMargin
        var left = input.lineLeft
        var right: CGFloat?
        if let element = input.elementFrame?.standardized, element.width > minimumContainerWidth {
            let inset = contentInset(lineLeft: input.lineLeft, elementLeft: element.minX)
            left = left ?? (element.minX + inset)
            right = element.maxX - inset
        } else if let frame = input.inputFrame?.standardized, frame.width > minimumContainerWidth {
            left = left ?? (frame.minX + defaultContentInset)
            right = frame.maxX - defaultContentInset
        }
        let bandLeft = min(max(left ?? input.caretRect.minX, screenLeft), screenRight)
        let bandRight = max(min(right ?? screenRight, screenRight), bandLeft + 1)
        return bandLeft...bandRight
    }

    private static func contentInset(lineLeft: CGFloat?, elementLeft: CGFloat) -> CGFloat {
        guard let lineLeft else { return defaultContentInset }
        let measured = lineLeft - elementLeft
        return (0...maximumBelievableInset).contains(measured) ? measured : defaultContentInset
    }
}
