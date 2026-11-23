import AppKit
import CoreGraphics
import Foundation

/// Where the caret will be once the host publishes text Cotabby just inserted. A word accept
/// re-anchors the remaining ghost before Accessibility reports the new caret, so the overlay
/// needs this estimate to keep the tail from waiting a poll behind the insert.
enum PredictedCaretAdvance {
    /// Estimates the caret rect after inserting a chunk by shifting the old caret in the text
    /// direction. LTR shifts right; RTL shifts left.
    /// When `observedCharWidth` is available (measured from real AX child frames), we use it
    /// directly — this matches the target app's actual font. Otherwise the field's resolved font
    /// measures the chunk (the host's true caret travel), and only a host with no usable style
    /// falls back to a system-font approximation.
    static func caretRect(
        after insertedChunk: String,
        oldCaretRect: CGRect,
        caretQuality: CaretGeometryQuality,
        observedCharWidth: CGFloat?,
        fieldStyle: ResolvedFieldStyle? = nil,
        isRightToLeft: Bool = false
    ) -> CGRect {
        let measuredWidth = chunkWidth(
            insertedChunk: insertedChunk,
            observedCharWidth: observedCharWidth,
            fieldStyle: fieldStyle
        )
        let appliedWidth: CGFloat

        switch caretQuality {
        case .exact, .derived, .layoutEstimated:
            // `.layoutEstimated` is unreachable here in practice — prediction always receives the
            // context's raw resolver quality, and the layout repair only upgrades the overlay
            // geometry, never the context. Folded into the trusted arm to keep the switch
            // exhaustive with the semantics it would want anyway.
            appliedWidth = measuredWidth

        case .estimated:
            // Estimated caret geometry is already low-confidence. If we apply the full predicted
            // shift after every Tab, the overlay can visibly march away from the real caret before
            // AX catches up. We still keep this path separate from trusted geometry, but we apply
            // an explicit upward bias here because the previous tuning was visibly lagging in
            // larger editors that only expose coarse AXFrame fallbacks.
            let estimatedPredictionBias: CGFloat = 1.5
            let conservativeCap = max(
                CGFloat(34) * estimatedPredictionBias,
                CGFloat(insertedChunk.count) * 13 * estimatedPredictionBias
            )
            appliedWidth = min(
                max(measuredWidth * 0.91 * estimatedPredictionBias, 14 * estimatedPredictionBias),
                conservativeCap
            )
        }

        let shift = isRightToLeft ? -appliedWidth : appliedWidth
        return CGRect(
            x: oldCaretRect.origin.x + shift,
            y: oldCaretRect.origin.y,
            width: oldCaretRect.width,
            height: oldCaretRect.height
        )
    }

    private static func chunkWidth(
        insertedChunk: String,
        observedCharWidth: CGFloat?,
        fieldStyle: ResolvedFieldStyle? = nil
    ) -> CGFloat {
        if let observed = observedCharWidth {
            return observed * CGFloat(insertedChunk.count)
        }

        // The field's own font is the host's true caret travel; the system-14 fallback measured
        // TextEdit's Helvetica 12 a quarter too wide, and the resulting overshoot surfaced as a
        // corrective snap once AX published the real caret.
        if let hostAdvance = InsertedTextAdvance.width(of: insertedChunk, style: fieldStyle) {
            return hostAdvance
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14)
        ]
        return (insertedChunk as NSString).size(withAttributes: attrs).width
    }
}
