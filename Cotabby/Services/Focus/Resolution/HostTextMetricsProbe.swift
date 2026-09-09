import AppKit
import ApplicationServices
import Foundation
import Logging

/// File overview:
/// Measures how the focused host renders text next to the caret, using the host's own bounds
/// answers rather than font tables: the rendered width of the text just before the caret, the box
/// of the caret's visual line, and the distance to the previous line. `GhostFontResolver` uses the
/// width to pick the typeface a web host names only by size, and `GhostTextLayout` uses the line
/// box and pitch to start wrapped rows exactly where the host starts its next line.
///
/// Native TextKit hosts answer every query (`AXLineForIndex`, `AXRangeForLine`, `AXBoundsForRange`).
/// Chromium answers `AXBoundsForRange` for `<textarea>`/`<input>` once its inline text boxes have
/// loaded (the first query after focus returns an empty rect, which `HostTextMetricsCache` retries),
/// reports nonsense line indices, and answers nothing for contenteditable, which then contributes
/// no metrics at all. Each measurement is a handful of synchronous cross-process calls, so callers
/// must run it once per field, never per poll tick.
@MainActor
enum HostTextMetricsProbe {
    struct Input {
        let element: AXUIElement
        /// Caret offset in the host's own document coordinates (what the NSRange APIs expect).
        let caretLocation: Int
        /// The element's text, used to pick the sample slice and to verify line strings.
        let text: String
        /// Offset of the caret inside `text` (window-relative when the text was windowed).
        let caretLocationInText: Int
        /// Height of the caret box. A width sample must come from one visual line, and a host that
        /// exposes no line geometry can only be checked by comparing the sample box to this.
        let caretHeight: CGFloat
        let supportedParameterizedAttributes: Set<String>
        /// The element's frame in Cocoa coordinates, anchoring the AX-rect coordinate validation.
        let anchorFrame: CGRect?
    }

    /// Longest sample measured before the caret. Long enough to average out per-glyph rounding,
    /// short enough to stay inside one line for typical fields.
    static let maximumSampleUTF16 = 32
    /// Most single-character bounds queries a pitch scan may spend (see `scannedPitch`).
    static let maximumPitchProbes = 24

    static func measure(_ input: Input) -> HostTextMetrics? {
        guard input.supportedParameterizedAttributes.contains(kAXBoundsForRangeParameterizedAttribute as String) else {
            return nil
        }
        let line = lineGeometry(input)
        let sample = widthSample(input, lineStart: line?.range.location)
        let usable = sample.flatMap { $0.isUsable ? $0 : nil }
        let scannedPitch = line?.pitch == nil ? scannedPitch(input) : nil
        let metrics = HostTextMetrics(
            sampleText: usable?.text,
            sampleWidth: usable?.width,
            lineRect: line?.rect,
            linePitch: line?.pitch ?? scannedPitch
        )
        if CotabbyLogger.focus.logLevel <= .debug {
            CotabbyLogger.focus.debug(
                "Host text metrics probe",
                metadata: [
                    "stage": .string("host-metrics-probe"),
                    "sample": .string(sample?.text ?? ""),
                    "sample_w": .stringConvertible(Double(sample?.width ?? 0)),
                    "sample_h": .stringConvertible(Double(sample?.height ?? 0)),
                    "sample_rejected": .string(sample?.rejection ?? ""),
                    "line_known": .stringConvertible(line != nil),
                    "line_rect": .string(line.map { Self.describe($0.rect) } ?? ""),
                    "line_pitch": .stringConvertible(Double(line?.pitch ?? scannedPitch ?? 0)),
                    "pitch_source": .string(line?.pitch != nil ? "line-api" : (scannedPitch != nil ? "scan" : "")),
                    "anchor": .string(input.anchorFrame.map(Self.describe) ?? ""),
                    "caret": .stringConvertible(input.caretLocation),
                    "caret_h": .stringConvertible(Double(input.caretHeight))
                ]
            )
        }
        guard !metrics.isEmpty else { return nil }
        return metrics
    }

    private static func describe(_ rect: CGRect) -> String {
        String(format: "%.1f,%.1f %.1fx%.1f", rect.minX, rect.minY, rect.width, rect.height)
    }

    private struct LineGeometry {
        let range: NSRange
        let rect: CGRect
        let pitch: CGFloat?
    }

    private struct WidthSample {
        let text: String
        let width: CGFloat
        let height: CGFloat
        /// Set when the measured box was unusable (multi-line); the sample then carries no width.
        let rejection: String?

        var isUsable: Bool { rejection == nil }
    }

    /// The caret line's range, its rendered box, and the pitch to the line above (TextKit hosts).
    private static func lineGeometry(_ input: Input) -> LineGeometry? {
        let params = input.supportedParameterizedAttributes
        guard params.contains(kAXLineForIndexParameterizedAttribute as String),
              params.contains(kAXRangeForLineParameterizedAttribute as String),
              let lineIndex = AXHelper.parameterizedIntValue(
                  for: kAXLineForIndexParameterizedAttribute as CFString,
                  parameter: input.caretLocation,
                  on: input.element
              ),
              lineIndex >= 0, lineIndex < 100_000,
              let lineRange = AXHelper.parameterizedRangeValue(
                  for: kAXRangeForLineParameterizedAttribute as CFString,
                  parameter: lineIndex,
                  on: input.element
              ),
              lineRange.length > 0,
              let lineRect = cocoaBounds(for: lineRange, input)
        else {
            return nil
        }
        var pitch: CGFloat?
        if lineIndex > 0,
           let previousRange = AXHelper.parameterizedRangeValue(
               for: kAXRangeForLineParameterizedAttribute as CFString,
               parameter: lineIndex - 1,
               on: input.element
           ),
           let previousRect = cocoaBounds(for: previousRange, input) {
            let delta = previousRect.minY - lineRect.minY
            if delta > 2, delta < 200 {
                pitch = delta
            }
        }
        return LineGeometry(range: lineRange, rect: lineRect, pitch: pitch)
    }

    /// The pitch found by asking the bounds of single characters at word starts before, then after,
    /// the caret. Hosts whose line APIs give no usable line above need it: Chromium's line indices
    /// are unreliable, and a caret on a field's first line has no line above at all (the lines below
    /// serve then). The reference box is the character next to the caret rather than the line box,
    /// so both sides of the comparison are the same kind of box. Word starts are probed because they
    /// are spaced like the host's wrap points. Web engines snap each line's top to whole pixels, so
    /// one line's delta carries up to a pixel of rounding (Chrome at line-height 16.25px answered 16
    /// and 17 on consecutive lines); the scan keeps going within its budget and divides the farthest
    /// delta by the number of lines it spans, which recovers the fractional pitch.
    private static func scannedPitch(_ input: Input) -> CGFloat? {
        let nsText = input.text as NSString
        let caret = min(max(input.caretLocationInText, 0), nsText.length)
        let documentOffset = input.caretLocation - input.caretLocationInText
        let referenceIndex = caret > 0 ? caret - 1 : caret
        guard referenceIndex < nsText.length,
              let reference = cocoaBounds(for: NSRange(location: referenceIndex + documentOffset, length: 1), input)
        else {
            return nil
        }
        let tolerance = max(2, input.caretHeight * 0.4)
        var probes = 0
        /// Walks word starts from `from` in `step` direction, recording the delta of every box that
        /// sits on a line further from the reference than the last one seen. Returns (farthest
        /// delta, lines spanned), or nil when nothing answered from another line.
        func walk(from: Int, step: Int, lineIsAbove: Bool) -> (CGFloat, Int)? {
            var index = from
            var farthest: CGFloat = 0
            var lines = 0
            while index > 0, index < nsText.length, probes < maximumPitchProbes {
                defer { index += step }
                guard isWordStart(nsText, index) else { continue }
                probes += 1
                guard let rect = cocoaBounds(for: NSRange(location: index + documentOffset, length: 1), input) else { continue }
                let delta = lineIsAbove ? rect.minY - reference.minY : reference.minY - rect.minY
                guard delta > farthest + tolerance else { continue }
                // A box hundreds of points away is not the next text line: distrust the whole walk.
                guard delta < 200 * CGFloat(lines + 1) else { return nil }
                farthest = delta
                lines += 1
            }
            return lines > 0 ? (farthest, lines) : nil
        }
        if let (delta, lines) = walk(from: referenceIndex - 1, step: -1, lineIsAbove: true) {
            return delta / CGFloat(lines)
        }
        if let (delta, lines) = walk(from: caret + 1, step: 1, lineIsAbove: false) {
            return delta / CGFloat(lines)
        }
        return nil
    }

    private static func isWordStart(_ text: NSString, _ index: Int) -> Bool {
        func isSpace(_ position: Int) -> Bool {
            CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(text.character(at: position)) ?? " ")
        }
        return !isSpace(index) && (index == 0 || isSpace(index - 1))
    }

    /// Rendered width of up to `maximumSampleUTF16` units immediately before the caret on the same
    /// line. Trailing spaces are excluded from the sample because hosts may collapse or hang them.
    private static func widthSample(_ input: Input, lineStart: Int?) -> WidthSample? {
        let nsText = input.text as NSString
        let caret = min(max(input.caretLocationInText, 0), nsText.length)
        guard caret > 0 else { return nil }
        // Offset between the windowed text's coordinates and the host's document coordinates.
        let documentOffset = input.caretLocation - input.caretLocationInText
        var begin = max(0, caret - maximumSampleUTF16)
        if let lineStart {
            begin = max(begin, min(lineStart - documentOffset, caret))
        }
        var end = caret
        let window = nsText.substring(with: NSRange(location: begin, length: caret - begin))
        if let lastBreak = window.utf16.lastIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            begin += window.utf16.distance(from: window.utf16.startIndex, to: lastBreak) + 1
        }
        while end > begin, CharacterSet.whitespaces.contains(UnicodeScalar(nsText.character(at: end - 1)) ?? " ") {
            end -= 1
        }
        guard end - begin >= 2 else { return nil }
        let range = NSRange(location: begin + documentOffset, length: end - begin)
        guard let rect = cocoaBounds(for: range, input), rect.width > 1 else { return nil }
        let text = nsText.substring(with: NSRange(location: begin, length: end - begin))
        // A range that spans a soft wrap comes back as the union box of both lines: its width is
        // the wider line, not the text's advance. Hosts with line geometry never hand us such a
        // range (the sample starts at the line start); the others are checked by height.
        let spansLines = lineStart == nil && input.caretHeight > 0 && rect.height > input.caretHeight * 1.6
        return WidthSample(text: text, width: rect.width, height: rect.height, rejection: spansLines ? "multi-line" : nil)
    }

    private static func cocoaBounds(for range: NSRange, _ input: Input) -> CGRect? {
        guard let raw = AXHelper.parameterizedRectValue(
            for: kAXBoundsForRangeParameterizedAttribute as CFString,
            range: range,
            on: input.element
        ), !raw.isEmpty, AXHelper.rectHasFiniteComponents(raw) else {
            return nil
        }
        let cocoa = AXHelper.validatedCocoaTextRect(fromAccessibilityRect: raw, anchorFrame: input.anchorFrame)
        if let anchor = input.anchorFrame, !anchor.isEmpty {
            let halo = anchor.insetBy(dx: -80, dy: -80)
            guard halo.contains(CGPoint(x: cocoa.midX, y: cocoa.midY)) else { return nil }
        }
        return cocoa
    }
}
