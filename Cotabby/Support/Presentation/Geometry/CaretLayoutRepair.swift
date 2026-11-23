import CoreGraphics
import Foundation

/// Decides which caret rect the overlay anchors to when the Accessibility geometry cannot be
/// trusted on its own. Pure with respect to coordinator state: everything it reads arrives in the
/// focused-input context, so the substitution rule can be exercised without a running pipeline.
enum CaretLayoutRepair {
    /// Repairs untrustworthy caret anchors with a hidden-text-layout estimate before presentation.
    ///
    /// The repair's authority is scoped by where the AX geometry came from, not just its quality:
    ///   - `.estimated` (AXFrame-only hosts): the AX guess has no real position at all, so a
    ///     passing estimate always replaces it. Applies to web and native hosts alike, because
    ///     there is no real measurement to protect.
    ///   - `.derived` in a native host: never repaired, the estimator does not run. Native AX
    ///     per-character bounds come from the app's real layout manager and reflect rendering the
    ///     uniform hidden layout cannot model (Notes renders a 23pt title line above 16pt body
    ///     lines, plus paragraph spacing, so the layout "disagrees" within a few lines while AX is
    ///     exactly right). A vertical mismatch there indicts the estimate, not AX.
    ///   - `.derived` with measured run frames (Gmail/Outlook child-run hosts): the rect's Y is a
    ///     real rendered line, so it is always kept and the estimator does not run at all; the
    ///     layout estimate cannot beat measurement (and is blind to blank lines those hosts
    ///     collapse out of the AX text).
    ///   - `.derived` web content without run frames (previous-character bounds through a web
    ///     engine's AX bridge, which has known wrong-line pathologies): the estimate (calibrated
    ///     with whatever the host revealed) only overrides the AX rect when the two disagree
    ///     vertically by more than `verticallyAgrees` tolerates; on agreement the AX rect is kept.
    ///
    /// On substitution the overlay geometry is upgraded to `.layoutEstimated`, which the render
    /// policy trusts for inline ghost text; on rejection the passed rect and quality survive
    /// untouched. The context itself is never mutated — resolver truth stays intact for
    /// reconciliation and caret prediction.
    ///
    /// `pendingInsertion` exists for the word-accept path: the synthetic insert has not been
    /// published back through AX yet, so `context.precedingText` is pre-insertion while the caret
    /// belongs after the inserted chunk. Appending the chunk lets the layout place the caret where
    /// the text actually is, including a wrap onto the next line that a pure X-shift cannot model.
    static func layoutRepairedAnchor(
        for context: FocusedInputContext,
        fallbackRect: CGRect,
        pendingInsertion: String,
        isRightToLeft: Bool
    ) -> LayoutRepairedAnchor {
        let quality = context.caretQuality
        guard quality == .estimated || quality == .derived else {
            return LayoutRepairedAnchor(rect: fallbackRect, quality: quality, outcome: nil, skipReason: nil)
        }

        // A caret inside a wrapped paragraph run (CodeMirror in Obsidian, see `WrappedRunAnchor`):
        // the paragraph is laid out in the run's own frame at the sibling runs' pitch, and the
        // line the caret lands on is placed from the union's top. That geometry is measured (frame
        // and pitch) except for the x inside the line, which is the host font's advance.
        // A one-line run is not laid out again: its frame is the host's own line box, so the
        // Accessibility caret already has the right line and only its x is approximate (the pixel
        // read corrects that at presentation). Laying it out put the caret fourteen lines up.
        if let edges = context.observedContentEdges, let wrapped = edges.wrappedRun, !wrapped.spansOneLine {
            return wrappedRunAnchor(
                edges: edges, context: context, fallbackRect: fallbackRect,
                pendingInsertion: pendingInsertion, isRightToLeft: isRightToLeft
            )
        }

        // Derived rects carry a real AX measurement, so whether the estimate may second-guess
        // them depends on who produced the measurement. Both bypasses skip the estimator
        // entirely rather than computing a diagnostic they can never act on: this path runs
        // inside the accept keystroke's handling window, where every spent millisecond of layout
        // work on a large flat prefix is pure risk during a rapid Tab burst.
        if quality == .derived {
            // Native hosts: per-character bounds come from the app's own layout manager and are
            // ground truth, while the uniform hidden layout cannot model rich text (Notes' taller
            // title line and paragraph spacing put it a line off within a few paragraphs). Only
            // web engines' AX bridges have the wrong-line pathologies the override exists for.
            if !context.isWebContentField {
                return LayoutRepairedAnchor(
                    rect: fallbackRect, quality: .derived, outcome: nil, skipReason: .nativeHostGeometry
                )
            }
            // Run-measured derived rects are kept unconditionally: run frames carry the host's
            // real line positions, including blank lines some hosts omit from the AX text. The
            // provenance check matters because content edges can now also come from the host's
            // line-query attributes, which describe a left margin but carry no line information —
            // letting those skip the repair would leave a wrong-line web caret uncorrected. A
            // one-line run (`WrappedRunAnchor.spansOneLine`) is such a frame too: it is the host's
            // own line box, and the pixel read corrects its x at presentation.
            if context.observedContentEdges?.isRunMeasured == true
                || context.observedContentEdges?.wrappedRun?.spansOneLine == true {
                return LayoutRepairedAnchor(
                    rect: fallbackRect, quality: .derived, outcome: nil, skipReason: .runMeasuredGeometry
                )
            }
        }

        // A `.derived` rect's height is a real rendered line box (previous-character bounds); the
        // `.estimated` AXFrame fallback's height is the whole field, which the estimator's
        // sanitizer would discard anyway — pass it for derived geometry only.
        let observedLineHeight: CGFloat? = quality == .derived ? context.caretRect.height : nil

        // Truncation is checked against the captured window, not the appended insertion: only the
        // snapshot capture can silently drop the document start.
        let input = TextLayoutCaretEstimator.Input(
            precedingText: context.precedingText + pendingInsertion,
            fieldFrame: context.inputFrameRect,
            fieldStyle: context.resolvedFieldStyle,
            isRightToLeft: isRightToLeft,
            prefixMayBeTruncated:
                context.precedingText.utf16.count >= FocusedInputSnapshot.textWindowUTF16,
            observedLineHeight: observedLineHeight,
            observedCharWidth: context.observedCharWidth,
            observedContentEdges: context.observedContentEdges
        )
        let outcome = TextLayoutCaretEstimator.estimate(for: input)
        switch outcome {
        case .estimate(let estimate):
            if quality == .derived, verticallyAgrees(estimate: estimate, axRect: fallbackRect) {
                // Same line: keep the AX rect, whose X carries the host's real glyph positions.
                return LayoutRepairedAnchor(rect: fallbackRect, quality: .derived, outcome: outcome, skipReason: nil)
            }
            return LayoutRepairedAnchor(
                rect: estimate.caretRect, quality: .layoutEstimated, outcome: outcome, skipReason: nil
            )
        case .rejected:
            return LayoutRepairedAnchor(rect: fallbackRect, quality: quality, outcome: outcome, skipReason: nil)
        }
    }

    /// Lays the wrapped paragraph out inside its run frame and returns the caret's line box there.
    /// The estimator judges a field's shape from its frame height and rejects content taller than
    /// the frame, but a union frame grows with its paragraph and the throttled run walk can report
    /// it a few lines short of the live text (measured: every estimate rejected for vertical
    /// overflow while a paragraph was being typed), so the layout frame is opened far below the
    /// run: only its top edge and width place the caret. The caret rect is the sibling runs' line
    /// box at the laid-out line's top, which is where the host draws that line.
    static func wrappedRunAnchor(
        edges: ObservedContentEdges,
        context: FocusedInputContext,
        fallbackRect: CGRect,
        pendingInsertion: String,
        isRightToLeft: Bool
    ) -> LayoutRepairedAnchor {
        guard let wrapped = edges.wrappedRun, let pitch = edges.linePitch ?? edges.lineBoxHeight, pitch > 0,
              wrapped.frame.width > 0
        else {
            return LayoutRepairedAnchor(rect: fallbackRect, quality: .estimated, outcome: nil, skipReason: nil)
        }
        let frame = wrapped.frame
        let layoutHeight = max(frame.height, pitch * 60)
        let layoutFrame = CGRect(x: frame.minX, y: frame.maxY - layoutHeight, width: frame.width, height: layoutHeight)
        let input = TextLayoutCaretEstimator.Input(
            precedingText: wrapped.paragraphTextBeforeCaret + pendingInsertion,
            fieldFrame: layoutFrame,
            fieldStyle: context.resolvedFieldStyle,
            isRightToLeft: isRightToLeft,
            prefixMayBeTruncated: false,
            observedLineHeight: pitch,
            observedCharWidth: context.observedCharWidth,
            observedContentEdges: ObservedContentEdges(leftX: frame.minX, topY: frame.maxY)
        )
        let outcome = TextLayoutCaretEstimator.estimate(for: input)
        guard case .estimate(let estimate) = outcome else {
            return LayoutRepairedAnchor(rect: fallbackRect, quality: .estimated, outcome: outcome, skipReason: nil)
        }
        let lineBox = edges.lineBoxHeight ?? pitch
        let lineTop = frame.maxY - CGFloat(estimate.lineIndex) * pitch
        let rect = CGRect(x: estimate.caretRect.minX, y: lineTop - lineBox, width: 2, height: lineBox)
        return LayoutRepairedAnchor(rect: rect, quality: .derived, outcome: outcome, skipReason: nil)
    }

    /// Vertical agreement test between the AX-derived caret and the layout estimate. Tolerance is
    /// three-quarters of a line: same-line measurements differ by baseline and padding subtleties,
    /// while the failure this repairs (the caret mapped into a neighboring visual line) is off by
    /// at least one full line box.
    private static func verticallyAgrees(
        estimate: TextLayoutCaretEstimator.Estimate,
        axRect: CGRect
    ) -> Bool {
        let tolerance = max(10, estimate.caretRect.height * 0.75)
        return abs(estimate.caretRect.midY - axRect.midY) <= tolerance
    }

    /// What one layout-repair attempt decided the overlay geometry should anchor to, plus the
    /// estimator outcome for structured logging (nil when repair did not apply at all).
    struct LayoutRepairedAnchor {
        let rect: CGRect
        let quality: CaretGeometryQuality
        let outcome: TextLayoutCaretEstimator.Outcome?
        /// Why a derived rect bypassed the estimator without running it (nil when the estimator
        /// ran, or when repair was out of scope for the quality entirely). Logged so "the caret
        /// came from trusted AX and repair stood down" is distinguishable from "this field never
        /// triggered repair" when diagnosing a misplaced overlay from the JSONL stream.
        let skipReason: LayoutRepairSkipReason?

        /// Whether the anchor is a layout estimate whose line was placed from default insets, not
        /// host measurements. Only an estimate that replaced the AX rect counts: a kept AX rect
        /// carries the host's own line, whatever the estimate it was checked against measured.
        var isCaretLineVerticallyUncalibrated: Bool {
            guard quality == .layoutEstimated, case .estimate(let estimate)? = outcome else {
                return false
            }
            return !estimate.isVerticallyCalibrated
        }
    }

    /// Why `layoutRepairedAnchor` kept a derived AX rect without running the estimator at all.
    /// Raw values feed the structured log stream.
    enum LayoutRepairSkipReason: String {
        /// Native (non-web) host: AX-derived geometry is ground truth for the trust policy.
        case nativeHostGeometry = "native_host_geometry"
        /// The rect was measured from child text-run frames, which outrank any estimate.
        case runMeasuredGeometry = "run_measured_geometry"
    }
}
