import AppKit
import Foundation
import Logging
import ScreenCaptureKit

/// File overview:
/// Measures the caret's line and x inside a union-framed paragraph from the host's own pixels.
///
/// Where it applies: hosts that expose a wrapped paragraph as ONE static-text run and answer no
/// bounds query for anything inside it (Obsidian's CodeMirror, measured 2026-09-09). For those,
/// Accessibility gives the paragraph's frame and its text and nothing else; the caret used to be
/// laid out inside that frame with an approximated font, which put the ghost five or six points
/// left of the real caret on wrapped lines and, with no sibling runs to calibrate from, on top of
/// the host's own glyphs. The host has already painted the answer: the caret sits where the
/// paragraph's last visual line ends.
///
/// Scope: a caret at the end of its paragraph (the common case while typing) is the end of the last
/// inked line. A caret with text after it on its line gets the card, not a ghost, and the card needs
/// only its line and x: those are found by walking the text before the caret through the painted
/// lines' ink widths (`midLineCaret`), because the host broke its lines where their ink ends.
///
/// The same measurement serves a single-line field that answers no bounds query at all. Chrome's
/// address bar is the measured case (2026-09-10): `AXBoundsForRange` returns a zero rect for every
/// range, the font dictionary is empty, and the only geometry is the field's frame; a text-layout
/// estimate in a guessed font put the caret close, never exactly, and the ghost went to the card.
/// The field paints one line, so its ink's right edge is the caret and the caret box is centred on
/// that ink (`singleLineCaretHeight`).
///
/// Lifecycle: owned by `OverlayController`, one per app. Measurements are cached per field and
/// paragraph text so the many presentations of one suggestion (stability-gate re-presents, the
/// return from a card) reuse one capture; a keystroke changes the text, so the next generation
/// measures again, unless the ghost lies over the run, when the run's last capture is carried
/// forward by the typed text's advance instead (`extrapolatedMeasurement(for:)`). Captures
/// exclude Cotabby's own windows, and an excluded window comes back black, so a ghost on screen
/// is never mistaken for host text and never read through either.
@MainActor
final class PixelCaretLocator {
    struct Request: Equatable {
        let focusedInputIdentityKey: UInt64
        /// The union run's frame in global Cocoa coordinates.
        let runFrame: CGRect
        /// The caret's paragraph up to the caret. Its trailing spaces are not painted, so their
        /// advance is added to the measured ink edge.
        let paragraphTextBeforeCaret: String
        /// Line pitch and line-box height from sibling runs when the host had any; nil otherwise.
        let siblingLinePitch: CGFloat?
        let siblingLineBoxHeight: CGFloat?
        /// Advance of one space in the ghost's font, for the unpainted trailing spaces.
        let spaceAdvance: CGFloat
        /// Points between the last painted glyph's ink and the caret: that glyph's right side
        /// bearing in the ghost's font (see `trailingInkGap(after:font:)`), or the average gap
        /// when the glyph is unknown.
        var trailingInkGap: CGFloat = PixelCaretLocator.inkToCaretGap
        /// For a single-line field: the height of the caret box to report, centred on the ink the
        /// field paints (the box the host would have reported, had it answered). Nil for a wrapped
        /// paragraph, whose line boxes come from the frame and pitch instead.
        var singleLineCaretHeight: CGFloat? = nil
        /// Points captured above and below the frame. A one-line run inside a paragraph editor sits
        /// four points from its neighbours' line boxes, and the full padding took their ascenders
        /// and descenders for lines of its own: most reads of Obsidian's one-line paragraphs
        /// failed that way (measured 2026-09-10).
        var verticalPadding: CGFloat = PixelCaretLocator.padding
        /// The ghost's face, whose advances carry a captured caret forward over text typed since
        /// the capture (`extrapolatedMeasurement(for:)`). Nil disables that.
        var font: NSFont? = nil
        /// Whether a fresh capture for this request feeds its field's advance fit (see
        /// `HostAdvanceFit`): set by the caller for a web field that reports no size, in a face its
        /// pixels named or, in a single-line field, its stand-in (`OverlayController.takesHostAdvance`).
        var recordsAdvance = false
        /// True when text follows the caret on its line, so the caret is not where the line's ink
        /// ends: it is found among the painted lines from the text before it (see
        /// `midLineCaret(lines:scale:region:text:font:)`), which needs `font`. Such a caret places
        /// the card, never an inline ghost. Claude's composer answers nothing for it: without this
        /// the card stood under the field's right edge, 400pt from a caret moved back into the
        /// middle of a line (measured 2026-09-11, 144 presentations).
        var caretIsMidLine = false
        /// Host advance the field's fit must span before it is adopted: `HostAdvanceFit.minimumSpan`
        /// for a paragraph's line, `singleLineMinimumSpan` for a single-line field's shorter text.
        var advanceFitMinimumSpan: CGFloat = HostAdvanceFit.minimumSpan

        /// Identifies the run (field, left edge, top and height) independently of its text and
        /// width: a one-line run's frame widens as the host catches up with the typing, while a
        /// wrap onto a new line changes its height.
        var runKey: String {
            let frame = "\(Int(runFrame.minX.rounded())),\(Int(runFrame.maxY.rounded())),\(Int(runFrame.height.rounded()))"
            return "\(focusedInputIdentityKey)|\(frame)"
        }

        /// The run and how its caret is read: a caret at the end of the ink and one inside the line
        /// are found differently, so one never stands in for the other, cached or carried forward.
        var captureKey: String {
            caretIsMidLine ? runKey + "|mid" : runKey
        }

        /// The screen region captured for this request.
        var captureRegion: CGRect {
            runFrame.insetBy(dx: -PixelCaretLocator.padding, dy: -verticalPadding)
        }

        var cacheKey: String {
            "\(captureKey)|\(paragraphTextBeforeCaret.hashValue)"
        }
    }

    struct Measurement: Equatable {
        /// The caret box in global Cocoa coordinates: x after the last painted glyph plus trailing
        /// spaces, the caret line's box for y and height.
        let caretRect: CGRect
        /// The caret line's box: `runFrame.minX` on the left (the paragraph's content edge), the
        /// full run width, the measured line's top and height.
        let lineRect: CGRect
        let linePitch: CGFloat?
        let lineIndex: Int
        let lineCount: Int
        /// Where the caret line's letters sit, as an offset below the caret box top, read from the
        /// same capture; nil when the line painted nothing (a blank last line). A calibration strip
        /// cut around a box that was itself a guess measured 15.0 where 16.0 was right on some
        /// Obsidian lines (2026-09-10); the baseline in the capture that found the caret is not a
        /// second measurement, it is the same one.
        var baselineOffsetFromTop: CGFloat? = nil
        /// Width in points of the ink on the caret's line, first glyph to last. The typeface
        /// match trims the paragraph tail it renders to what fits this width, because a wrapped
        /// paragraph's tail runs back into the previous visual line while the strip holds only
        /// the caret's line (Obsidian, 2026-09-10: sixteen searches of the wrong words, no match).
        var lineInkWidth: CGFloat? = nil
    }

    /// Points of slack captured around the run so a glyph touching the frame edge is not clipped.
    static let padding: CGFloat = 6
    /// Where the host draws its caret relative to the last glyph's ink when the glyph is unknown:
    /// the advance ends about a side bearing past the ink, which is under a point at text sizes.
    /// Measured word by word in Obsidian (2026-09-10), a fixed gap after a "t" in the system face
    /// put the ghost half a point right of the accepted text; the glyph's own bearing is used
    /// whenever the text and face are known.
    static let inkToCaretGap: CGFloat = 0.75
    /// Bearings outside this range are not a text glyph's (a symbol, a missing glyph) and fall
    /// back to the average gap.
    static let trailingInkGapRange: ClosedRange<CGFloat> = 0...1.5

    /// The right side bearing of the last non-space character of `text` in `font`: how far the
    /// caret sits past that glyph's ink. Nil when the text ends in whitespace, is empty, or the
    /// glyph cannot be measured.
    nonisolated static func trailingInkGap(after text: String, font: NSFont) -> CGFloat? {
        guard let character = text.last(where: { !$0.isWhitespace }) else { return nil }
        var units = Array(String(character).utf16)
        guard units.count == 1 else { return nil }
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font as CTFont, &units, &glyph, 1), glyph != 0 else { return nil }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, &glyph, &advance, 1)
        var box = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font as CTFont, .horizontal, &glyph, &box, 1)
        guard advance.width > 0, !box.isNull, box.width > 0 else { return nil }
        let bearing = advance.width - box.maxX
        return trailingInkGapRange.contains(bearing) ? bearing : nil
    }
    private static let cacheLimit = 8
    /// Characters typed since a capture beyond which its caret is no longer carried forward by
    /// arithmetic. The ghost's face reproduces the host's advances to about a percent (measured
    /// word by word in Obsidian, 2026-09-10: two device pixels over eight words), which over a
    /// suggestion's length stays under a pixel and over a paragraph would not.
    static let maximumExtrapolatedCharacters = 48

    private var cache: [String: Measurement] = [:]
    private var cacheOrder: [String] = []
    private var failures: Set<String> = []
    /// The latest capture per run, the base every extrapolation on that run starts from (never an
    /// extrapolation itself, so their error does not compound).
    private var latestCaptures: [String: (request: Request, measurement: Measurement)] = [:]
    private var latestCaptureOrder: [String] = []
    private var inFlight: [String: [@MainActor (Measurement?) -> Void]] = [:]
    private var shareableContent: SCShareableContent?
    private let permissionCheck: () -> Bool
    /// Called on the main actor with every fresh capture's request and measurement (never a cached
    /// or carried-forward one), so the overlay can fit the host's advance from real reads only.
    var onFreshCapture: (@MainActor (Request, Measurement) -> Void)?

    init(permissionCheck: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() }) {
        self.permissionCheck = permissionCheck
    }

    func cachedMeasurement(for request: Request) -> Measurement? {
        cache[request.cacheKey]
    }

    /// True when this request already failed once; callers then take their fallback immediately
    /// instead of holding a presentation for a capture that will not help.
    func hasFailed(_ request: Request) -> Bool {
        failures.contains(request.cacheKey)
    }

    /// The caret for a paragraph typed further since the run's latest capture, without a new
    /// capture: that caret moved right by the advance of the characters typed, in the ghost's own
    /// face. The overlay uses this while its ghost lies over the run, where a capture would read
    /// the panel instead of the host (see `OverlayController.panelCovers`); measured in Obsidian
    /// (2026-09-10), the alternative of re-anchoring to the Accessibility estimate put the ghost
    /// four lines up, or off screen, on every other keystroke of a typed-through suggestion.
    /// The result is cached under the request like a capture, so the same text presents from it
    /// again; nil when the run has no capture, the text changed other than by typing on, or the
    /// arithmetic cannot be trusted (see `extrapolated(from:for:)`).
    func extrapolatedMeasurement(for request: Request) -> Measurement? {
        guard let base = latestCaptures[request.captureKey],
              let measurement = Self.extrapolated(from: base, for: request) else { return nil }
        store(measurement, for: request.cacheKey)
        Self.logExtrapolation(measurement, base: base.request, request: request)
        return measurement
    }

    /// The pure arithmetic of `extrapolatedMeasurement(for:)`: nil unless `request` names the same
    /// run and its text extends the base's by typed characters only (no line break, at most
    /// `maximumExtrapolatedCharacters`), the request carries a face to measure them in, and the
    /// moved caret is still inside the run's frame (past it the paragraph wrapped, and a capture
    /// is needed).
    nonisolated static func extrapolated(
        from base: (request: Request, measurement: Measurement), for request: Request
    ) -> Measurement? {
        guard base.request.captureKey == request.captureKey, let font = request.font,
              let typed = appendedText(from: base.request.paragraphTextBeforeCaret, to: request.paragraphTextBeforeCaret)
        else { return nil }
        let advance = GhostFontResolver.width(of: typed, font: font)
        guard advance > 0 else { return nil }
        var caretRect = base.measurement.caretRect
        caretRect.origin.x += advance
        guard caretRect.minX <= request.runFrame.maxX + request.spaceAdvance * 2 + 1 else { return nil }
        return Measurement(
            caretRect: caretRect,
            lineRect: base.measurement.lineRect,
            linePitch: base.measurement.linePitch,
            lineIndex: base.measurement.lineIndex,
            lineCount: base.measurement.lineCount,
            baselineOffsetFromTop: base.measurement.baselineOffsetFromTop,
            lineInkWidth: base.measurement.lineInkWidth.map { $0 + advance }
        )
    }

    /// What was typed at the end of `base` to reach `text`, when that is all that changed.
    nonisolated static func appendedText(from base: String, to text: String) -> String? {
        guard text.count > base.count, text.hasPrefix(base) else { return nil }
        let typed = String(text.dropFirst(base.count))
        guard typed.count <= maximumExtrapolatedCharacters, !typed.contains(where: \.isNewline) else { return nil }
        return typed
    }

    /// Starts a measurement, or joins the one in flight for the same key. `completion` runs on the
    /// main actor with nil when the pixels did not yield a caret.
    func locate(_ request: Request, completion: @escaping @MainActor (Measurement?) -> Void) {
        let key = request.cacheKey
        if let cached = cache[key] {
            completion(cached)
            return
        }
        if inFlight[key] != nil {
            inFlight[key]?.append(completion)
            return
        }
        guard permissionCheck(), request.runFrame.width > 8, request.runFrame.height > 4 else {
            failures.insert(key)
            completion(nil)
            return
        }
        inFlight[key] = [completion]
        let requested = request.captureRegion
        Task { @MainActor [weak self] in
            guard let self else { return }
            let started = Date()
            var measurement: Measurement?
            var failure = "capture"
            do {
                // The region is snapped to whole pixels before capture (see the calibrator: a
                // fractional edge makes ScreenCaptureKit resample and blur the glyphs), and the
                // rows and columns map back through the rect that was really captured.
                let (captured, region) = try await self.capture(requested)
                let analysis = await Task.detached(priority: .userInitiated) {
                    InkCaretAnalyzer.measure(captured.bitmap)
                }.value
                if let analysis {
                    measurement = Self.measurement(from: analysis, scale: captured.scale, region: region, request: request)
                    failure = measurement == nil ? "geometry" : ""
                } else {
                    failure = "no-ink"
                }
                if Self.dumpsCaptures {
                    Self.dumpCapture(captured, region: region, request: request, analysis: analysis, measurement: measurement, failure: failure)
                }
            } catch {
                failure = "capture: \(error.localizedDescription)"
            }
            let listeners = self.inFlight.removeValue(forKey: key) ?? []
            if let measurement {
                self.store(measurement, for: key)
                self.recordLatestCapture(measurement, for: request)
                self.onFreshCapture?(request, measurement)
            } else {
                self.failures.insert(key)
            }
            Self.log(measurement, failure: failure, request: request, elapsedMilliseconds: Int(Date().timeIntervalSince(started) * 1000))
            for listener in listeners {
                listener(measurement)
            }
        }
    }

    // MARK: - Geometry

    /// Maps the analyzer's rows and columns back to screen points and picks the caret line.
    ///
    /// The caret line is the last inked line. The frame's height says how many lines the host laid
    /// out (one line box plus a pitch per extra line); when the pixels show one fewer, the last line
    /// is blank (the paragraph wrapped exactly at its end) and the caret sits at that blank line's
    /// start. The pitch comes from the pixels when two or more lines were painted with baselines
    /// that can be a pitch, else from sibling runs. Failing both, lines the pixels show share the
    /// frame evenly, which puts the caret on its line within a point or two; that share is not
    /// reported as the pitch, so the ghost's rows take the one the host style measured before
    /// (`OverlayController.linePitch(for:fontSize:)`). Without it the frame itself was taken for the
    /// caret's line box, two lines tall after a wrap. With one painted line and no pitch the frame is
    /// the one line.
    ///
    /// A caret with text after it on its line (`caretIsMidLine`) is placed among the painted lines
    /// by `midLineCaret(lines:scale:region:text:font:)` instead.
    nonisolated static func measurement(
        from analysis: InkCaretAnalyzer.Measurement,
        scale: CGFloat,
        region: CGRect,
        request: Request
    ) -> Measurement? {
        guard scale > 0, !analysis.lines.isEmpty else { return nil }
        if let caretHeight = request.singleLineCaretHeight {
            return singleLineMeasurement(from: analysis, scale: scale, region: region, request: request, caretHeight: caretHeight)
        }
        let frame = request.runFrame
        let paintedCount = analysis.lines.count
        let measuredPitch = analysis.pitchRows.map { CGFloat($0) / scale } ?? request.siblingLinePitch
        let pitch = measuredPitch ?? (paintedCount >= 2 ? frame.height / CGFloat(paintedCount) : nil)
        // The number of line boxes the frame holds; only meaningful once the pitch is known.
        var lineCount = paintedCount
        var lineBox = frame.height
        if let pitch, pitch > 0 {
            let boxes = ((frame.height - (request.siblingLineBoxHeight ?? pitch)) / pitch).rounded() + 1
            lineCount = max(paintedCount, Int(boxes))
            lineBox = request.siblingLineBoxHeight ?? max(pitch * 0.6, frame.height - CGFloat(lineCount - 1) * pitch)
        }
        guard lineBox > 4, lineBox <= frame.height + 0.5 else { return nil }
        if request.caretIsMidLine {
            return midLineMeasurement(
                from: analysis, scale: scale, region: region, request: request,
                pitch: pitch, reportedPitch: measuredPitch, lineCount: lineCount, lineBox: lineBox
            )
        }
        let lineIndex = lineCount - 1
        let lineTop = frame.maxY - CGFloat(lineIndex) * (pitch ?? 0)
        let lineRect = CGRect(x: frame.minX, y: lineTop - lineBox, width: frame.width, height: lineBox)

        let caretX: CGFloat
        if paintedCount < lineCount {
            // Blank last line: the caret is at the paragraph's content edge.
            caretX = frame.minX + (CGFloat(analysis.lines[0].inkLeftColumn) / scale - padding)
        } else {
            let last = analysis.lines[paintedCount - 1]
            // Sanity: the painted line must lie inside the box the frame arithmetic assigned it.
            let inkTop = region.maxY - CGFloat(last.topRow) / scale
            let inkBottom = region.maxY - CGFloat(last.bottomRow + 1) / scale
            guard inkTop <= lineRect.maxY + 1, inkBottom >= lineRect.minY - 1 else { return nil }
            caretX = Self.caretX(on: last, region: region, scale: scale, request: request)
        }
        guard caretX >= frame.minX - 1, caretX <= frame.maxX + request.spaceAdvance * 2 + 1 else { return nil }
        let painted = paintedCount < lineCount ? nil : analysis.lines[paintedCount - 1]
        let baseline = painted.flatMap {
            baselineOffset(of: $0, lineTop: lineRect.maxY, lineBox: lineBox, region: region, scale: scale)
        }
        return Measurement(
            caretRect: CGRect(x: caretX, y: lineRect.minY, width: 2, height: lineBox),
            lineRect: lineRect,
            linePitch: measuredPitch,
            lineIndex: lineIndex,
            lineCount: lineCount,
            baselineOffsetFromTop: baseline,
            lineInkWidth: painted.map { CGFloat($0.textRightColumn - $0.inkLeftColumn + 1) / scale }
        )
    }

    /// The mid-line counterpart of `measurement(from:scale:region:request:)`: the caret's line and x
    /// come from `midLineCaret(lines:scale:region:text:font:)`, its box from the same frame
    /// arithmetic. No ink width is reported: the line's ink runs on past the caret, so it says
    /// nothing about the text before it.
    nonisolated static func midLineMeasurement(
        from analysis: InkCaretAnalyzer.Measurement,
        scale: CGFloat,
        region: CGRect,
        request: Request,
        pitch: CGFloat?,
        reportedPitch: CGFloat?,
        lineCount: Int,
        lineBox: CGFloat
    ) -> Measurement? {
        guard let font = request.font,
              let placement = midLineCaret(
                lines: analysis.lines, scale: scale, region: region, text: request.paragraphTextBeforeCaret, font: font
              ),
              placement.lineIndex < max(lineCount, analysis.lines.count)
        else { return nil }
        let frame = request.runFrame
        let lineTop = frame.maxY - CGFloat(placement.lineIndex) * (pitch ?? 0)
        let lineRect = CGRect(x: frame.minX, y: lineTop - lineBox, width: frame.width, height: lineBox)
        let painted = analysis.lines[placement.lineIndex]
        let inkTop = region.maxY - CGFloat(painted.topRow) / scale
        let inkBottom = region.maxY - CGFloat(painted.bottomRow + 1) / scale
        guard inkTop <= lineRect.maxY + 1, inkBottom >= lineRect.minY - 1,
              placement.x >= frame.minX - 1, placement.x <= frame.maxX + request.spaceAdvance * 2 + 1
        else { return nil }
        return Measurement(
            caretRect: CGRect(x: placement.x, y: lineRect.minY, width: 2, height: lineBox),
            lineRect: lineRect,
            linePitch: reportedPitch,
            lineIndex: placement.lineIndex,
            lineCount: max(lineCount, analysis.lines.count),
            baselineOffsetFromTop: baselineOffset(of: painted, lineTop: lineRect.maxY, lineBox: lineBox, region: region, scale: scale),
            lineInkWidth: nil
        )
    }

    /// Where the caret sits on its painted line: the centre of the host's own caret bar when the
    /// capture caught it right after a glyph (CodeMirror centres a 1.2px bar on the insertion
    /// point, in the text colour), else the last glyph's ink edge plus its side bearing and any
    /// trailing spaces, which the host paints nothing for. Read as the last glyph, the bar put the
    /// caret a point right, and five after a trailing space (measured 2026-09-10 in Obsidian).
    ///
    /// After trailing spaces the bar is not used: at the end of a line the host draws its caret
    /// short of the spaces' full advance, while the next character it paints lands at the full
    /// advance. Measured 2026-09-10 in Obsidian: the bar moved 3.5pt for a 4.19pt space, a ghost
    /// anchored on it landed half a point short of the accepted text, and across 676 captures the
    /// bar after a space sat 0.2 to 0.4pt left of the text's own ink plus its advances, against
    /// agreement within 0.1pt after most glyphs. The text's ink edge (the bar left out) plus the
    /// advances is where the next character goes.
    nonisolated static func caretX(on line: InkCaretAnalyzer.Line, region: CGRect, scale: CGFloat, request: Request) -> CGFloat {
        let trailingSpaces = request.paragraphTextBeforeCaret.reversed().prefix { $0 == " " || $0 == "\u{00A0}" }.count
        if let bar = line.caretBarColumns, trailingSpaces == 0 {
            return region.minX + CGFloat(bar.lowerBound + bar.upperBound + 1) / 2 / scale
        }
        let textRight = region.minX + CGFloat(line.textRightColumn + 1) / scale
        return textRight + request.trailingInkGap + CGFloat(trailingSpaces) * request.spaceAdvance
    }

    /// The line's baseline as an offset below `lineTop`, when the analyzer read one and it lies
    /// inside the line box (a little slack for a box whose bottom the frame arithmetic guessed).
    /// Points of ink a line must span before its baseline is reported: a lone glyph's tapering
    /// bottom reads a row high (a wrapped line holding one "A" measured 15.0 for 16.0, and a
    /// two-letter address bar read 6.0).
    static let minimumBaselineInkWidth: CGFloat = 24
    /// Least depth below the line box's top a baseline may have, as a fraction of the box: letters
    /// sit on a baseline about four fifths of the way down their box. Over 4,823 dumped reads
    /// (2026-09-11) every sound single-line baseline lay half the box deep or more, and every one
    /// read under a capital's top bar (see `InkCaretAnalyzer.bodyRows(in:threshold:)`) a third of the
    /// way or less; a read that shallow is refused, and the ghost keeps the calibrated baseline.
    static let minimumBaselineDepthFraction: CGFloat = 0.45

    nonisolated static func baselineOffset(
        of line: InkCaretAnalyzer.Line, lineTop: CGFloat, lineBox: CGFloat, region: CGRect, scale: CGFloat
    ) -> CGFloat? {
        guard line.baselineRow > 0, CGFloat(line.textRightColumn - line.inkLeftColumn + 1) / scale >= minimumBaselineInkWidth else { return nil }
        let offset = lineTop - (region.maxY - CGFloat(line.baselineRow) / scale)
        guard offset > 0, offset >= lineBox * minimumBaselineDepthFraction, offset <= lineBox + 2 else { return nil }
        return offset
    }

    /// Tolerance for matching a line's ink to the advance of the words it holds, in points and as a
    /// fraction of the ink's width: the ghost's face reproduces the host's advances to a few tenths
    /// of a percent when the pixels named it (Claude's composer, 2026-09-11) and to a few percent for
    /// a stand-in face, and the ink leaves out the first glyph's left and the last glyph's right
    /// side bearing. Words are rarely closer than this, so the nearest word end is the host's break.
    static let midLineMatchTolerance: CGFloat = 4
    static let midLineMatchFraction: CGFloat = 0.025

    /// Where a caret with text after it on its line sits among the painted lines. The host broke the
    /// paragraph where each painted line's ink ends, so the text before the caret is walked a line at
    /// a time: while more of it remains than a line's ink holds, that line takes the words whose
    /// advance in the ghost's face comes closest to its ink width, and the walk moves on to the next
    /// line. The line whose ink runs on past what remains holds the caret, which is that remainder's
    /// advance past the line's start (the first glyph's ink less its left side bearing). A text
    /// whose remainder ends in spaces right where a line's ink does puts the caret at the next
    /// line's start: the host wrapped there. Nil when a line's ink matches no word end (the face or
    /// the text disagrees with the pixels) or the text outruns the painted lines.
    nonisolated static func midLineCaret(
        lines: [InkCaretAnalyzer.Line], scale: CGFloat, region: CGRect, text: String, font: NSFont
    ) -> (lineIndex: Int, x: CGFloat)? {
        let string = text as NSString
        let length = string.length
        guard length > 0, scale > 0 else { return nil }
        let typeset = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        // Advance from the paragraph's start to a UTF-16 offset, kerning included.
        func advance(to index: Int) -> CGFloat { CTLineGetOffsetForStringIndex(typeset, index, nil) }
        func isSpace(_ index: Int) -> Bool {
            let unit = string.character(at: index)
            return unit == 0x20 || unit == 0xA0
        }
        var start = 0
        for (index, line) in lines.enumerated() {
            // A wrapped line starts at its first letter; the spaces the host broke at hang off the line above.
            while start < length, isSpace(start) { start += 1 }
            let inkLeft = region.minX + CGFloat(line.inkLeftColumn) / scale
            if start == length {
                // Only spaces remained: the caret is where this line starts.
                return (index, inkLeft)
            }
            let inkWidth = CGFloat(line.textRightColumn - line.inkLeftColumn + 1) / scale
            let tolerance = max(midLineMatchTolerance, inkWidth * midLineMatchFraction)
            let origin = advance(to: start)
            let lineStart = inkLeft - leftSideBearing(of: string, at: start, font: font)
            var restEnd = length
            while restEnd > start, isSpace(restEnd - 1) { restEnd -= 1 }
            if advance(to: restEnd) - origin < inkWidth - tolerance {
                return (index, lineStart + advance(to: length) - origin)
            }
            // The word end whose advance from the line's start comes closest to the ink's width.
            var best: (end: Int, next: Int, error: CGFloat)?
            var cursor = start
            while cursor < length {
                var wordEnd = cursor
                while wordEnd < length, !isSpace(wordEnd) { wordEnd += 1 }
                var next = wordEnd
                while next < length, isSpace(next) { next += 1 }
                let width = advance(to: wordEnd) - origin
                let error = abs(width - inkWidth)
                if best.map({ error < $0.error }) ?? true {
                    best = (wordEnd, next, error)
                }
                if width > inkWidth + tolerance { break }
                cursor = next
            }
            guard let found = best, found.error <= tolerance else { return nil }
            if found.end >= restEnd {
                if restEnd < length, index + 1 < lines.count {
                    return (index + 1, region.minX + CGFloat(lines[index + 1].inkLeftColumn) / scale)
                }
                return (index, lineStart + advance(to: length) - origin)
            }
            start = found.next
        }
        return nil
    }

    /// The left side bearing of the glyph for the UTF-16 unit at `index`: how far right of the pen
    /// its ink starts. Zero when the glyph cannot be measured or is not a text glyph's.
    nonisolated static func leftSideBearing(of string: NSString, at index: Int, font: NSFont) -> CGFloat {
        guard index < string.length else { return 0 }
        var unit = string.character(at: index)
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font as CTFont, &unit, &glyph, 1), glyph != 0 else { return 0 }
        var box = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font as CTFont, .horizontal, &glyph, &box, 1)
        guard !box.isNull, box.width > 0, abs(box.minX) < font.pointSize * 0.3 else { return 0 }
        return box.minX
    }

    /// A field that is one line: the caret follows the ink of the line painted in it (the widest
    /// block, should a stray mark also qualify as a line), and the caret box is the requested
    /// height centred on that ink, kept inside the frame, so the baseline policy and the calibrator
    /// see the box a native host would have reported.
    nonisolated static func singleLineMeasurement(
        from analysis: InkCaretAnalyzer.Measurement,
        scale: CGFloat,
        region: CGRect,
        request: Request,
        caretHeight: CGFloat
    ) -> Measurement? {
        guard let line = analysis.lines.max(by: {
            ($0.inkRightColumn - $0.inkLeftColumn) < ($1.inkRightColumn - $1.inkLeftColumn)
        }) else { return nil }
        let frame = request.runFrame
        let inkTop = region.maxY - CGFloat(line.topRow) / scale
        let inkBottom = region.maxY - CGFloat(line.bottomRow + 1) / scale
        guard inkTop <= frame.maxY + 1, inkBottom >= frame.minY - 1 else { return nil }
        let inkRight = region.minX + CGFloat(line.inkRightColumn + 1) / scale
        let caretX: CGFloat
        if request.caretIsMidLine {
            // The line's ink runs on past the caret, wherever it ends.
            guard let font = request.font,
                  let placement = midLineCaret(lines: [line], scale: scale, region: region, text: request.paragraphTextBeforeCaret, font: font),
                  placement.lineIndex == 0
            else { return nil }
            caretX = placement.x
        } else {
            // Ink running into the region's right edge goes on past it: the caret is further right
            // than anything this capture shows.
            guard inkRight < region.maxX - 1 else { return nil }
            caretX = Self.caretX(on: line, region: region, scale: scale, request: request)
        }
        guard caretX >= frame.minX - 1, caretX <= frame.maxX + request.spaceAdvance * 2 + 1 else { return nil }
        let height = min(max(caretHeight, 4), frame.height)
        let centre = (inkTop + inkBottom) / 2
        let bottom = min(max(centre - height / 2, frame.minY), frame.maxY - height)
        return Measurement(
            caretRect: CGRect(x: caretX, y: bottom, width: 2, height: height),
            lineRect: CGRect(x: frame.minX, y: bottom, width: frame.width, height: height),
            linePitch: nil,
            lineIndex: 0,
            lineCount: 1,
            baselineOffsetFromTop: baselineOffset(of: line, lineTop: bottom + height, lineBox: height, region: region, scale: scale),
            lineInkWidth: request.caretIsMidLine ? nil : CGFloat(line.textRightColumn - line.inkLeftColumn + 1) / scale
        )
    }

    // MARK: - Capture

    private struct Captured {
        let bitmap: RGBABitmap
        let scale: CGFloat
    }

    private func capture(_ requested: CGRect) async throws -> (Captured, CGRect) {
        let content = try await currentShareableContent()
        let desktop = NSScreen.screens.map(\.frame).reduce(into: CGRect.null) { $0 = $0.union($1) }
        let scale = NSScreen.screens.first { $0.frame.contains(CGPoint(x: requested.midX, y: requested.midY)) }?.backingScaleFactor ?? 2
        let region = HostBaselineCalibrator.snappedToPixels(requested, scale: scale)
        let regionCG = CGRect(x: region.minX, y: desktop.maxY - region.maxY, width: region.width, height: region.height)
        guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: regionCG.midX, y: regionCG.midY)) }) else {
            throw LocatorError.noDisplay
        }
        let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = regionCG.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        configuration.width = max(Int((region.width * scale).rounded()), 1)
        configuration.height = max(Int((region.height * scale).rounded()), 1)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        let image: CGImage = try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: LocatorError.noImage)
                }
            }
        }
        guard let bitmap = RGBABitmap(image) else { throw LocatorError.noImage }
        return (Captured(bitmap: bitmap, scale: CGFloat(image.height) / region.height), region)
    }

    private func currentShareableContent() async throws -> SCShareableContent {
        if let shareableContent { return shareableContent }
        let content: SCShareableContent = try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(throwing: LocatorError.noDisplay)
                }
            }
        }
        shareableContent = content
        return content
    }

    private enum LocatorError: Error {
        case noDisplay
        case noImage
    }

    // MARK: - Capture dumps (developer diagnostics)

    /// Debug-only, under the calibrator's strip switch
    /// (`defaults write <bundle> cotabbyDumpCalibrationStrips -bool YES`): every caret capture is
    /// written as a PNG plus a JSON sidecar (run frame, region, the text's tail, the analyzer's
    /// lines and the caret they gave) next to the strips, so a caret read a point off can be
    /// examined on exactly the pixels it came from. Off by default.
    private static let dumpsCaptures = UserDefaults.standard.bool(forKey: "cotabbyDumpCalibrationStrips")

    private nonisolated static func dumpCapture(
        _ captured: Captured,
        region: CGRect,
        request: Request,
        analysis: InkCaretAnalyzer.Measurement?,
        measurement: Measurement?,
        failure: String
    ) {
        let folder = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/\(ProcessInfo.processInfo.processName)/strips", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let bitmap = captured.bitmap
        if let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: bitmap.width, pixelsHigh: bitmap.height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: bitmap.width * 4, bitsPerPixel: 32
        ), let data = representation.bitmapData {
            bitmap.bytes.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: bitmap.bytes.count) }
            try? representation.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("caret-\(stamp).png"))
        }
        func values(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height].map { Double($0) } }
        var sidecar: [String: Any] = [
            "run_frame": values(request.runFrame),
            "region": values(region),
            "scale": Double(captured.scale),
            "text_tail": String(request.paragraphTextBeforeCaret.suffix(60)),
            "trailing_ink_gap": Double(request.trailingInkGap),
            "single_line": request.singleLineCaretHeight != nil,
            "failure": failure
        ]
        if let analysis {
            sidecar["lines"] = analysis.lines.map { [$0.topRow, $0.bottomRow, $0.inkLeftColumn, $0.inkRightColumn] }
            sidecar["pitch_rows"] = analysis.pitchRows ?? 0
        }
        if let measurement {
            sidecar["caret"] = values(measurement.caretRect)
        }
        if let json = try? JSONSerialization.data(withJSONObject: sidecar) {
            try? json.write(to: folder.appendingPathComponent("caret-\(stamp).json"))
        }
    }

    private func store(_ measurement: Measurement, for key: String) {
        if cache[key] == nil {
            cacheOrder.append(key)
            if cacheOrder.count > Self.cacheLimit {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
        }
        cache[key] = measurement
        failures.remove(key)
    }

    private func recordLatestCapture(_ measurement: Measurement, for request: Request) {
        let key = request.captureKey
        if latestCaptures[key] == nil {
            latestCaptureOrder.append(key)
            if latestCaptureOrder.count > Self.cacheLimit {
                latestCaptures.removeValue(forKey: latestCaptureOrder.removeFirst())
            }
        }
        latestCaptures[key] = (request, measurement)
    }

    private static func logExtrapolation(_ measurement: Measurement, base: Request, request: Request) {
        guard CotabbyLogger.suggestion.logLevel <= .debug else { return }
        CotabbyLogger.suggestion.debug(
            "Pixel caret carried forward",
            metadata: [
                "stage": .string("pixel-caret-extrapolated"),
                "run_frame": .string(String(
                    format: "%.0f,%.0f %.0fx%.0f",
                    request.runFrame.minX, request.runFrame.maxY, request.runFrame.width, request.runFrame.height
                )),
                "typed_since": .stringConvertible(request.paragraphTextBeforeCaret.count - base.paragraphTextBeforeCaret.count),
                "paragraph_chars": .stringConvertible(request.paragraphTextBeforeCaret.count),
                "caret_x": .stringConvertible(Double(measurement.caretRect.minX)),
                "caret_top": .stringConvertible(Double(measurement.caretRect.maxY))
            ]
        )
    }

    private static func log(_ measurement: Measurement?, failure: String, request: Request, elapsedMilliseconds: Int) {
        guard CotabbyLogger.suggestion.logLevel <= .debug else { return }
        var metadata: Logger.Metadata = [
            "stage": .string(measurement == nil ? "pixel-caret-failed" : "pixel-caret"),
            "elapsed_ms": .stringConvertible(elapsedMilliseconds),
            "run_frame": .string(String(
                format: "%.0f,%.0f %.0fx%.0f",
                request.runFrame.minX, request.runFrame.maxY, request.runFrame.width, request.runFrame.height
            )),
            "paragraph_chars": .stringConvertible(request.paragraphTextBeforeCaret.count)
        ]
        if let measurement {
            metadata["caret_x"] = .stringConvertible(Double(measurement.caretRect.minX))
            metadata["caret_top"] = .stringConvertible(Double(measurement.caretRect.maxY))
            metadata["caret_h"] = .stringConvertible(Double(measurement.caretRect.height))
            metadata["line_index"] = .stringConvertible(measurement.lineIndex)
            metadata["line_count"] = .stringConvertible(measurement.lineCount)
            metadata["line_pitch"] = .stringConvertible(Double(measurement.linePitch ?? 0))
            metadata["baseline_offset"] = .stringConvertible(Double(measurement.baselineOffsetFromTop ?? 0))
        } else {
            metadata["reason"] = .string(failure)
        }
        CotabbyLogger.suggestion.debug(measurement == nil ? "Pixel caret unavailable" : "Pixel caret measured", metadata: metadata)
    }
}
