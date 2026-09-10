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
/// Scope, deliberately narrow: only a caret at the end of its paragraph is measured (the common
/// case while typing), because then the caret is the end of the last inked line. A caret inside a
/// paragraph keeps whatever the caller would have done without this service.
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

        /// Identifies the run (field, left edge, top and height) independently of its text and
        /// width: a one-line run's frame widens as the host catches up with the typing, while a
        /// wrap onto a new line changes its height.
        var runKey: String {
            let frame = "\(Int(runFrame.minX.rounded())),\(Int(runFrame.maxY.rounded())),\(Int(runFrame.height.rounded()))"
            return "\(focusedInputIdentityKey)|\(frame)"
        }

        /// The screen region captured for this request.
        var captureRegion: CGRect {
            runFrame.insetBy(dx: -PixelCaretLocator.padding, dy: -verticalPadding)
        }

        var cacheKey: String {
            "\(runKey)|\(paragraphTextBeforeCaret.hashValue)"
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
        guard let base = latestCaptures[request.runKey],
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
        guard base.request.runKey == request.runKey, let font = request.font,
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
    /// start. The line box and pitch come from the pixels when two or more lines were painted,
    /// else from sibling runs, else the frame itself is the one line.
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
        let pixelPitch = analysis.pitchRows.map { CGFloat($0) / scale }
        let pitch = pixelPitch ?? request.siblingLinePitch
        let paintedCount = analysis.lines.count
        // The number of line boxes the frame holds; only meaningful once the pitch is known.
        var lineCount = paintedCount
        var lineBox = frame.height
        if let pitch, pitch > 0 {
            let boxes = ((frame.height - (request.siblingLineBoxHeight ?? pitch)) / pitch).rounded() + 1
            lineCount = max(paintedCount, Int(boxes))
            lineBox = request.siblingLineBoxHeight ?? max(pitch * 0.6, frame.height - CGFloat(lineCount - 1) * pitch)
        }
        guard lineBox > 4, lineBox <= frame.height + 0.5 else { return nil }
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
            let inkRight = region.minX + CGFloat(last.inkRightColumn + 1) / scale
            let trailingSpaces = request.paragraphTextBeforeCaret.reversed().prefix { $0 == " " || $0 == "\u{00A0}" }.count
            caretX = inkRight + request.trailingInkGap + CGFloat(trailingSpaces) * request.spaceAdvance
        }
        guard caretX >= frame.minX - 1, caretX <= frame.maxX + request.spaceAdvance * 2 + 1 else { return nil }
        let painted = paintedCount < lineCount ? nil : analysis.lines[paintedCount - 1]
        let baseline = painted.flatMap {
            baselineOffset(of: $0, lineTop: lineRect.maxY, lineBox: lineBox, region: region, scale: scale)
        }
        return Measurement(
            caretRect: CGRect(x: caretX, y: lineRect.minY, width: 2, height: lineBox),
            lineRect: lineRect,
            linePitch: pitch,
            lineIndex: lineIndex,
            lineCount: lineCount,
            baselineOffsetFromTop: baseline,
            lineInkWidth: painted.map { CGFloat($0.inkRightColumn - $0.inkLeftColumn + 1) / scale }
        )
    }

    /// The line's baseline as an offset below `lineTop`, when the analyzer read one and it lies
    /// inside the line box (a little slack for a box whose bottom the frame arithmetic guessed).
    /// Points of ink a line must span before its baseline is reported: a lone glyph's tapering
    /// bottom reads a row high (a wrapped line holding one "A" measured 15.0 for 16.0, and a
    /// two-letter address bar read 6.0).
    static let minimumBaselineInkWidth: CGFloat = 24

    nonisolated static func baselineOffset(
        of line: InkCaretAnalyzer.Line, lineTop: CGFloat, lineBox: CGFloat, region: CGRect, scale: CGFloat
    ) -> CGFloat? {
        guard line.baselineRow > 0, CGFloat(line.inkRightColumn - line.inkLeftColumn + 1) / scale >= minimumBaselineInkWidth else { return nil }
        let offset = lineTop - (region.maxY - CGFloat(line.baselineRow) / scale)
        guard offset > 0, offset <= lineBox + 2 else { return nil }
        return offset
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
        // Ink running into the region's right edge goes on past it: the caret is further right
        // than anything this capture shows.
        guard inkRight < region.maxX - 1 else { return nil }
        let trailingSpaces = request.paragraphTextBeforeCaret.reversed().prefix { $0 == " " || $0 == "\u{00A0}" }.count
        let caretX = inkRight + request.trailingInkGap + CGFloat(trailingSpaces) * request.spaceAdvance
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
            lineInkWidth: CGFloat(line.inkRightColumn - line.inkLeftColumn + 1) / scale
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
        let key = request.runKey
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
