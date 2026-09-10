import AppKit
import CoreGraphics
import Foundation
import Logging
import ScreenCaptureKit

/// File overview:
/// Measures where a web host really paints its text baseline, from the host's own pixels, so the
/// ghost can sit on it to the device pixel.
///
/// Why pixels: Chromium and WebKit report caret and character boxes through Accessibility rounded
/// to whole points, but they lay lines out at fractional positions (a 1.6 line-height on 18px text
/// puts every line top at a different fraction) and snap the painted baseline to device pixels.
/// `GhostBaselinePolicy` recovers the engine's rounded ascent exactly, yet the fraction the AX
/// rounding discarded still leaves the ghost up to one device pixel off; measured live in Chrome,
/// a textarea's text sat 11.5pt below its 12pt-ascent box top and a contenteditable's second line
/// 16.5pt below a 17pt one. Nothing in AX exposes that fraction. One small capture of the text
/// left of the caret does.
///
/// Cost model: one ScreenCaptureKit screenshot of a strip a few hundred points wide, once per
/// (field, line, font size), started while the model is still generating so the answer is
/// normally cached before the ghost first appears. Screen Recording is optional in Cotabby; without
/// it this service does nothing and the policy baseline stands.
@MainActor
final class HostBaselineCalibrator {
    struct Key: Hashable {
        let focusedInputIdentityKey: UInt64
        /// Whole-point top of the caret line in Cocoa coordinates.
        let lineTop: Int
        let caretHeight: Int
        let fontPointSize: Int
    }

    struct Request {
        let key: Key
        let caretRect: CGRect
        /// Left edge of the host's content on this line when known; bounds the strip.
        let contentLeft: CGFloat?
        /// The policy baseline the measurement must stay close to.
        let policyOffset: CGFloat
        /// Text before the caret on its line; with `matchTypeface`, the strip is also compared
        /// against candidate faces rendering this text (see `TypefaceMatcher`).
        let lineText: String?
        let pointSize: CGFloat
        let matchTypeface: Bool
        /// Whether `pointSize` is the host's own report; see `TypefaceMatcher.Input.sizeIsReported`.
        let sizeIsReported: Bool
        /// Ink width of the caret's line when a pixel caret measured it; see
        /// `TypefaceMatcher.Input.lineInkWidth`.
        let lineInkWidth: CGFloat?
        /// Screen x from which Cotabby's own ghost panel covers the host. Captures exclude the
        /// app's windows, and an excluded region comes back black: a strip that reached under the
        /// panel carried nineteen black columns at its end (Chrome's address bar, 2026-09-10) and
        /// no face could correlate with it. The strip stops short of this edge.
        let occludedFrom: CGFloat?

        init(
            key: Key,
            caretRect: CGRect,
            contentLeft: CGFloat?,
            policyOffset: CGFloat,
            lineText: String? = nil,
            pointSize: CGFloat = 0,
            matchTypeface: Bool = false,
            sizeIsReported: Bool = false,
            lineInkWidth: CGFloat? = nil,
            occludedFrom: CGFloat? = nil
        ) {
            self.key = key
            self.caretRect = caretRect
            self.contentLeft = contentLeft
            self.policyOffset = policyOffset
            self.lineText = lineText
            self.pointSize = pointSize
            self.matchTypeface = matchTypeface
            self.sizeIsReported = sizeIsReported
            self.lineInkWidth = lineInkWidth
            self.occludedFrom = occludedFrom
        }
    }

    /// Typeface knowledge is per field, never per line and never per size guess: the face and size
    /// the host painted do not change from line to line, and keying by the caller's size (measured
    /// 2026-09-10) let one Obsidian field match Helvetica at 17 and Times New Roman at 20 as its
    /// caret box changed, so the ghost flipped between them.
    struct TypefaceKey: Hashable {
        let focusedInputIdentityKey: UInt64
    }

    /// What a field's pixels said its face and size are, with the evidence that said it.
    struct TypefaceMatchRecord: Equatable, Sendable {
        let fontName: String
        /// The size at which the face reproduced the host's ink (`TypefaceMatcher`).
        let pointSize: CGFloat
        let score: Double
        /// Characters of line text the match was made on; a materially longer line may improve
        /// a weak match (see `wantsTypefaceMatch`).
        let textLength: Int
        /// Strips analyzed for this field so far, matched or not; bounded by `maximumTypefaceAttempts`.
        let attempts: Int
    }

    struct Calibration: Equatable {
        /// Measured baseline offset below the caret box top.
        let baselineOffset: CGFloat
        /// The field's matched face and size, when one was asked for and the field has one.
        let typefaceMatch: TypefaceMatchRecord?
    }

    /// The field's background as painted, in two places: on the caret's line and on the line below
    /// it. They differ in editors that tint the current line (Xcode, VS Code); the ghost's caret-row
    /// band takes the first color and its continuation rows the second.
    struct HostBackground: Equatable, Sendable {
        let caretLine: RGBABitmap.Pixel
        let nextLine: RGBABitmap.Pixel
    }

    struct BackgroundRequest {
        let focusedInputIdentityKey: UInt64
        let caretRect: CGRect
        /// Vertical distance to the next line (the caret height when unknown).
        let linePitch: CGFloat?
        /// The field's content edges when known; the sampled region stays inside them so a page
        /// around a web field never counts as the field's background.
        let contentLeft: CGFloat?
        let contentRight: CGFloat?
        let contentBottom: CGFloat?
    }

    /// Widest strip of host text measured left of the caret.
    static let maximumStripWidth: CGFloat = 240
    /// Narrower strips hold too few glyphs for a trustworthy body-row profile.
    static let minimumStripWidth: CGFloat = 24
    /// Gap kept between the strip and the caret so the caret bar never counts as ink.
    static let caretGap: CGFloat = 2
    static let verticalPadding: CGFloat = 2
    /// A measurement further than this from the policy baseline is not the same text line (a
    /// neighbouring line leaked in) and is rejected. WebKit's caret box for a loose CSS line-height
    /// is not the line box the policy assumes: Safari's Georgia contenteditable at line-height 1.6
    /// painted its baseline 3.5pt below the policy value, so the tolerance must admit that much.
    /// Underlines are excluded by the analyzer's contiguous-body rule, not by this bound.
    static let maximumCorrection: CGFloat = 4
    private static let cacheLimit = 64

    private var cache: [Key: CGFloat] = [:]
    private var cacheOrder: [Key] = []
    private var typefaces: [TypefaceKey: TypefaceMatchRecord] = [:]
    /// Strips analyzed for a field that has no record yet without naming a face; a field whose
    /// text never matches any candidate (an uninstalled face) stops being asked after
    /// `maximumTypefaceAttempts`, instead of paying a capture and a search on every keystroke.
    private var typefaceMisses: [TypefaceKey: Int] = [:]
    /// One typeface search at a time: a search is tens to hundreds of milliseconds of CPU beside
    /// the model, and a second strip captured meanwhile is no better evidence than the first.
    private var typefaceSearchInFlight = false
    /// Callers waiting on a measurement in flight, per key. A present that arrives while the
    /// generation-time prewarm is still capturing joins its measurement instead of being dropped.
    private var waiters: [Key: [@MainActor (Calibration) -> Void]] = [:]
    /// Background colors per field identity: a field keeps one background however many lines the
    /// caret visits, so this is measured once per field.
    private var backgrounds: [UInt64: HostBackground] = [:]
    private var backgroundWaiters: [UInt64: [@MainActor (HostBackground) -> Void]] = [:]
    private var shareableContent: SCShareableContent?

    private let permissionCheck: () -> Bool

    init(permissionCheck: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() }) {
        self.permissionCheck = permissionCheck
    }

    /// The measured baseline offset from the caret box top for this line, if already known.
    func cachedOffset(for key: Key) -> CGFloat? {
        cache[key]
    }

    /// The face and size the host's pixels matched for this field, if already known.
    func cachedTypeface(for key: TypefaceKey) -> TypefaceMatchRecord? {
        typefaces[key]
    }

    /// A match at or above this score stands for the field's life.
    static let settledTypefaceScore = 0.95
    /// A weaker match is retried once a line this much longer than its evidence is on screen.
    static let typefaceRetryExtraCharacters = 6
    /// A retry replaces the record only when its winner beats the recorded face by this much on
    /// the same strip.
    static let typefaceReplacementMargin = 0.02
    /// Strips a field is asked about at most; each costs a capture and tens of milliseconds.
    static let maximumTypefaceAttempts = 12

    /// Whether the pixels should be asked for the face again: always for a field with no record,
    /// and for a field whose record is weak (short text, modest score) once the caret's line has
    /// grown enough to be better evidence, a bounded number of times. A settled record is never
    /// re-measured, so the ghost's face cannot drift with the strip a keystroke leaves on screen.
    nonisolated static func wantsTypefaceMatch(known: TypefaceMatchRecord?, misses: Int = 0, lineText: String?) -> Bool {
        guard let known else { return misses < maximumTypefaceAttempts }
        guard known.score < settledTypefaceScore, known.attempts < maximumTypefaceAttempts, let lineText else { return false }
        return lineText.count >= known.textLength + typefaceRetryExtraCharacters
    }

    /// The field's record after one more strip. A first match is adopted as it is. A later ranking
    /// replaces the recorded face only when its winner beats that face ON THE SAME STRIP by
    /// `typefaceReplacementMargin`: scores from different strips are not comparable (measured
    /// 2026-09-10 in Obsidian: the system face scored 0.943 on one strip, then Arial scored 0.980
    /// on the next, where the system face itself scored 0.969, and a cross-strip comparison swapped
    /// the right answer for a wrong one). The same face matched again keeps its recorded size, so
    /// a quarter-point wobble between strips never resizes the ghost, and only raises its score.
    nonisolated static func updatedTypefaceRecord(
        known: TypefaceMatchRecord?,
        match: TypefaceMatcher.Match?,
        ranking: [TypefaceMatcher.Score],
        textLength: Int
    ) -> TypefaceMatchRecord? {
        guard let known else {
            guard let match else { return nil }
            return TypefaceMatchRecord(fontName: match.fontName, pointSize: match.pointSize, score: match.score, textLength: textLength, attempts: 1)
        }
        let attempts = known.attempts + 1
        guard let match else {
            return TypefaceMatchRecord(fontName: known.fontName, pointSize: known.pointSize, score: known.score, textLength: textLength, attempts: attempts)
        }
        if match.fontName == known.fontName {
            return TypefaceMatchRecord(
                fontName: known.fontName, pointSize: known.pointSize, score: max(known.score, match.score), textLength: textLength, attempts: attempts
            )
        }
        let knownOnThisStrip = ranking.first { $0.fontName == known.fontName }?.score ?? -1
        if match.score >= knownOnThisStrip + typefaceReplacementMargin {
            return TypefaceMatchRecord(fontName: match.fontName, pointSize: match.pointSize, score: match.score, textLength: textLength, attempts: attempts)
        }
        return TypefaceMatchRecord(fontName: known.fontName, pointSize: known.pointSize, score: known.score, textLength: textLength, attempts: attempts)
    }

    /// The field's measured background, if already known.
    func cachedBackground(for focusedInputIdentityKey: UInt64) -> HostBackground? {
        backgrounds[focusedInputIdentityKey]
    }

    /// Measures the field's background once, or joins the measurement in flight. `completion` runs
    /// on the main actor only when a fresh measurement arrives.
    func measureBackground(_ request: BackgroundRequest, completion: @escaping @MainActor (HostBackground) -> Void) {
        let identity = request.focusedInputIdentityKey
        guard backgrounds[identity] == nil, permissionCheck() else { return }
        if backgroundWaiters[identity] != nil {
            backgroundWaiters[identity]?.append(completion)
            return
        }
        guard let region = Self.backgroundRegion(request) else { return }
        backgroundWaiters[identity] = [completion]
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (captured, _) = try await self.capture(region)
                // Bitmap row 0 is the region's top, which is the caret box top; the caret's line
                // occupies the first `caretHeight` points of rows and the next line the rest.
                let caretLineRows = Int((request.caretRect.height * captured.scale).rounded())
                let background = await Task.detached(priority: .userInitiated) {
                    Self.sampleBackground(captured.bitmap, caretLineRows: caretLineRows)
                }.value
                let listeners = self.backgroundWaiters.removeValue(forKey: identity) ?? []
                guard let background else { return }
                if self.backgrounds.count >= Self.cacheLimit {
                    self.backgrounds.removeAll()
                }
                self.backgrounds[identity] = background
                Self.log(background, request: request)
                for listener in listeners {
                    listener(background)
                }
            } catch {
                self.backgroundWaiters.removeValue(forKey: identity)
                CotabbyLogger.suggestion.debug("Host background measurement failed: \(error.localizedDescription)")
            }
        }
    }

    /// Starts a measurement for `request` unless one is cached, or joins the one already in flight
    /// for the same key. `completion` runs on the main actor only when a fresh, accepted measurement
    /// arrives.
    func calibrate(_ request: Request, completion: @escaping @MainActor (Calibration) -> Void) {
        let key = request.key
        let typefaceKey = TypefaceKey(focusedInputIdentityKey: key.focusedInputIdentityKey)
        let needsTypeface = request.matchTypeface
            && Self.wantsTypefaceMatch(known: typefaces[typefaceKey], misses: typefaceMisses[typefaceKey] ?? 0, lineText: request.lineText)
        guard cache[key] == nil || needsTypeface, permissionCheck() else { return }
        let attemptTypeface = needsTypeface && !typefaceSearchInFlight
        if waiters[key] != nil {
            waiters[key]?.append(completion)
            return
        }
        guard let strip = Self.captureStrip(
            caretRect: request.caretRect, contentLeft: request.contentLeft, occludedFrom: request.occludedFrom
        ) else { return }
        waiters[key] = [completion]
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (captured, strip) = try await self.capture(strip)
                if Self.dumpsStrips {
                    Self.dumpStrip(captured, strip: strip, request: request, attemptTypeface: attemptTypeface)
                }
                let started = Date()
                if attemptTypeface { self.typefaceSearchInFlight = true }
                // Pixel analysis (row/column profiles, candidate renderings) runs off the main actor
                // so a focus poll never waits on it; only the bookkeeping below touches state.
                let analysis = await Task.detached(priority: .userInitiated) {
                    Self.analyze(captured, strip: strip, request: request, attemptTypeface: attemptTypeface)
                }.value
                if attemptTypeface { self.typefaceSearchInFlight = false }
                let listeners = self.waiters.removeValue(forKey: key) ?? []
                guard let analysis else { return }
                if analysis.baselineAccepted {
                    self.store(analysis.baselineOffset, for: key)
                }
                if analysis.typefaceAttempted {
                    // Only a strip the matcher actually searched, and whose letter bodies looked
                    // like a line of this font, counts as a miss; one declined for holding too
                    // little ink, or cut from somewhere that was not the caret's line, was never
                    // evidence either way.
                    if analysis.typefaceMatch == nil, self.typefaces[typefaceKey] == nil, !analysis.typefaceRanking.isEmpty,
                       analysis.baselineAccepted {
                        self.typefaceMisses[typefaceKey, default: 0] += 1
                    }
                    self.typefaces[typefaceKey] = Self.updatedTypefaceRecord(
                        known: self.typefaces[typefaceKey],
                        match: analysis.typefaceMatch,
                        ranking: analysis.typefaceRanking,
                        textLength: request.lineText?.count ?? 0
                    )
                }
                let record = request.matchTypeface ? self.typefaces[typefaceKey] : nil
                Self.log(analysis, request: request, elapsedMilliseconds: Int(Date().timeIntervalSince(started) * 1000))
                guard analysis.baselineAccepted || record != nil else { return }
                let calibration = Calibration(
                    baselineOffset: analysis.baselineAccepted ? analysis.baselineOffset : (self.cache[key] ?? request.policyOffset),
                    typefaceMatch: record
                )
                for listener in listeners {
                    listener(calibration)
                }
            } catch {
                self.waiters.removeValue(forKey: key)
                if attemptTypeface { self.typefaceSearchInFlight = false }
                CotabbyLogger.suggestion.debug("Baseline calibration failed: \(error.localizedDescription)")
            }
        }
    }

    private struct CapturedStrip: Sendable {
        let bitmap: RGBABitmap
        /// Device pixels per point in the capture.
        let scale: CGFloat
    }

    private struct Analysis: Sendable {
        let baselineOffset: CGFloat
        let baselineAccepted: Bool
        /// Height in device pixels of the letter bodies the baseline was read from; logged so a
        /// rejected measurement can be told apart from one that was never plausible.
        let bodyRows: Int
        /// A face and size found in this capture (nil when not asked for or not found).
        let typefaceMatch: TypefaceMatcher.Match?
        /// Every candidate's best showing on this strip (empty when not asked for).
        let typefaceRanking: [TypefaceMatcher.Score]
        let typefaceAttempted: Bool
    }

    /// Reads the baseline (and, when asked, the typeface) out of the captured strip. Pure; nil when
    /// the strip held no usable text.
    private nonisolated static func analyze(
        _ captured: CapturedStrip,
        strip: CGRect,
        request: Request,
        attemptTypeface: Bool
    ) -> Analysis? {
        guard let measurement = InkBaselineAnalyzer.measure(captured.bitmap) else { return nil }
        let measuredPoints = CGFloat(measurement.baselineRow) / captured.scale
        let offset = baselineOffset(fromCaretTop: request.caretRect.maxY, stripTop: strip.maxY, measured: measuredPoints)
        // Two independent checks, because they catch different failures: the letter bodies found in
        // the strip must be the right size for the font (a strip that caught a fragment, a partly
        // scrolled line, or a neighbouring line's descenders measures a baseline that is confidently
        // wrong), and the answer must sit near the policy prediction.
        let accepted = describesPlausibleBodies(measurement, pointSize: request.pointSize, scale: captured.scale)
            && hasEnoughInk(measurement)
            && accepts(measured: offset, policy: request.policyOffset)
        var match: TypefaceMatcher.Match?
        var ranking: [TypefaceMatcher.Score] = []
        var attempted = false
        if attemptTypeface, let lineText = request.lineText, request.pointSize > 0 {
            attempted = true
            // The matcher searches size as well as face, centred on the caller's size and on the
            // letter-body height just measured, so a caret-box size guess cannot mislead it.
            ranking = TypefaceMatcher.rank(
                TypefaceMatcher.Input(
                    strip: captured.bitmap,
                    scale: captured.scale,
                    caretColumn: (request.caretRect.minX - strip.minX) * captured.scale,
                    baselineRow: CGFloat(measurement.baselineRow),
                    text: lineText,
                    pointSize: request.pointSize,
                    bodyRows: measurement.baselineRow - measurement.bodyTopRow,
                    sizeIsReported: request.sizeIsReported,
                    lineInkWidth: request.lineInkWidth,
                    candidates: TypefaceMatcher.defaultCandidates(pointSize: request.pointSize)
                )
            )
            match = TypefaceMatcher.match(from: ranking)
        }
        return Analysis(
            baselineOffset: offset,
            baselineAccepted: accepted,
            bodyRows: measurement.baselineRow - measurement.bodyTopRow,
            typefaceMatch: match,
            typefaceRanking: ranking,
            typefaceAttempted: attempted
        )
    }

    // MARK: - Pure geometry

    /// The screen strip to measure, in Cocoa coordinates: host text left of the caret, the caret
    /// line's box plus a little vertical slack, stopping short of anything Cotabby's own panel
    /// covers. Nil when there is no room for enough text.
    nonisolated static func captureStrip(caretRect: CGRect, contentLeft: CGFloat?, occludedFrom: CGFloat? = nil) -> CGRect? {
        var right = caretRect.minX - caretGap
        if let occludedFrom {
            right = min(right, occludedFrom - 1)
        }
        var left = right - maximumStripWidth
        if let contentLeft {
            left = max(left, contentLeft)
        }
        guard right - left >= minimumStripWidth, caretRect.height > 0 else { return nil }
        return CGRect(
            x: left,
            y: caretRect.minY - verticalPadding,
            width: right - left,
            height: caretRect.height + 2 * verticalPadding
        )
    }

    /// The region whose pixels give the background: the caret's line box plus the line below it, a
    /// neighbourhood of the caret bounded by the field's content edges. The line below is where a
    /// continuation row will paint, and it is measured separately because the caret's own line may
    /// carry a current-line tint. Nil when the field offers too little width.
    nonisolated static func backgroundRegion(_ request: BackgroundRequest) -> CGRect? {
        let caret = request.caretRect
        var left = caret.minX - maximumStripWidth / 2
        var right = caret.minX + maximumStripWidth / 2
        if let contentLeft = request.contentLeft {
            left = max(left, contentLeft)
        }
        if let contentRight = request.contentRight {
            right = min(right, contentRight)
        }
        guard right - left >= minimumStripWidth, caret.height > 0 else { return nil }
        let pitch = max(request.linePitch ?? caret.height, caret.height)
        var bottom = caret.minY - pitch
        if let contentBottom = request.contentBottom {
            bottom = max(bottom, min(contentBottom, caret.minY))
        }
        return CGRect(x: left, y: bottom, width: right - left, height: caret.maxY - bottom)
    }

    /// Splits the captured region at the caret box bottom and takes the dominant color of each part.
    /// A field whose bottom edge sits right under the caret line has no next-line pixels of its own;
    /// the caret line's color stands in.
    nonisolated static func sampleBackground(_ bitmap: RGBABitmap, caretLineRows: Int) -> HostBackground? {
        guard let caretLine = HostBackgroundSampler.dominantColor(in: bitmap, rows: 0..<caretLineRows) else { return nil }
        let nextLine = HostBackgroundSampler.dominantColor(in: bitmap, rows: caretLineRows..<bitmap.height) ?? caretLine
        return HostBackground(caretLine: caretLine, nextLine: nextLine)
    }

    /// Converts a measured baseline (points below the strip's top) into an offset below the caret top.
    nonisolated static func baselineOffset(fromCaretTop caretTop: CGFloat, stripTop: CGFloat, measured: CGFloat) -> CGFloat {
        measured - (stripTop - caretTop)
    }

    nonisolated static func accepts(measured: CGFloat, policy: CGFloat) -> Bool {
        abs(measured - policy) <= maximumCorrection
    }

    /// Fraction of a font's ascent the detected letter bodies may span and still be believable.
    /// Body rows run from the tallest ascender down to the baseline, so they are close to the
    /// ascent for ordinary prose and shorter for an all-x-height line ("sensor was worn"); the
    /// floor allows that while rejecting a block far too small to be a line of this font.
    static let minimumBodyAscentFraction: CGFloat = 0.45
    static let maximumBodyAscentFraction: CGFloat = 1.35

    /// Ink pixels a strip must carry before its baseline is believed: about four glyphs at text
    /// sizes. Measured 2026-09-10 in Obsidian: a caret one character into a wrapped line left a
    /// strip holding a lone "A", whose tapering legs fell under the body threshold a row early,
    /// and the ghost sat a point high on every such line. One glyph's bottom is not a baseline.
    static let minimumBaselineInkPixels = 240

    nonisolated static func hasEnoughInk(_ measurement: InkBaselineAnalyzer.Measurement) -> Bool {
        measurement.inkPixelCount >= minimumBaselineInkPixels
    }

    /// Whether the ink the analyzer measured is the right size to BE this font's letter bodies.
    ///
    /// The baseline is only as good as the block it was read from. Measured in a real session, one
    /// field's lines read 12.0 and 15.0 for the same font and caret box: a 3pt spread, and the ghost
    /// on the 12.0 lines sat visibly high. Both readings passed the +/-4pt policy window, because
    /// that window only asks whether the answer is near the prediction, never whether the thing
    /// measured was a line of text at all.
    nonisolated static func describesPlausibleBodies(
        _ measurement: InkBaselineAnalyzer.Measurement,
        pointSize: CGFloat,
        scale: CGFloat
    ) -> Bool {
        guard pointSize > 0, scale > 0 else { return true }
        let bodyRows = CGFloat(measurement.baselineRow - measurement.bodyTopRow)
        guard bodyRows > 0 else { return false }
        let ascentPixels = NSFont.systemFont(ofSize: pointSize).ascender * scale
        guard ascentPixels > 0 else { return true }
        let fraction = bodyRows / ascentPixels
        return fraction >= minimumBodyAscentFraction && fraction <= maximumBodyAscentFraction
    }

    // MARK: - Strip dumps (developer diagnostics)

    /// Debug-only: with `defaults write <bundle> cotabbyDumpCalibrationStrips -bool YES`, every
    /// captured strip is written as a PNG plus a JSON sidecar (caret column, baseline request,
    /// line text) under ~/Library/Logs/<app>/strips, so a typeface search that declined on a live
    /// strip can be re-run offline on exactly the pixels it saw. Off by default; a session that
    /// leaves it on writes a file per calibration.
    private static let dumpsStrips = UserDefaults.standard.bool(forKey: "cotabbyDumpCalibrationStrips")

    private nonisolated static func dumpStrip(_ captured: CapturedStrip, strip: CGRect, request: Request, attemptTypeface: Bool) {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/\(ProcessInfo.processInfo.processName)/strips", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let bitmap = captured.bitmap
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: bitmap.width, pixelsHigh: bitmap.height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: bitmap.width * 4, bitsPerPixel: 32
        ), let data = representation.bitmapData else { return }
        bitmap.bytes.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: bitmap.bytes.count) }
        try? representation.representation(using: .png, properties: [:])?.write(to: logs.appendingPathComponent("strip-\(stamp).png"))
        let sidecar: [String: Any] = [
            "caret_column": Double((request.caretRect.minX - strip.minX) * captured.scale),
            "scale": Double(captured.scale),
            "point_size": Double(request.pointSize),
            "size_is_reported": request.sizeIsReported,
            "match_typeface": attemptTypeface,
            "line_text": request.lineText ?? "",
            "strip": [Double(strip.minX), Double(strip.minY), Double(strip.width), Double(strip.height)],
            "caret": [Double(request.caretRect.minX), Double(request.caretRect.minY), Double(request.caretRect.width), Double(request.caretRect.height)]
        ]
        if let json = try? JSONSerialization.data(withJSONObject: sidecar) {
            try? json.write(to: logs.appendingPathComponent("strip-\(stamp).json"))
        }
    }

    // MARK: - Capture

    /// Captures `requested` snapped outward to the display's pixel grid, and returns the rect it
    /// actually captured. A strip edge on a fractional pixel makes ScreenCaptureKit resample the
    /// whole image (a sub-pixel phase that drifts across the width): measured 2026-09-10 on
    /// Chrome's address bar, glyph stems came back four pixels wide instead of three and no
    /// candidate face correlated above 0.3, while a pixel-aligned screenshot of the same text
    /// scored 0.95. Whole pixels in, the copy is exact.
    private func capture(_ requested: CGRect) async throws -> (CapturedStrip, CGRect) {
        let content = try await currentShareableContent()
        let desktop = NSScreen.screens.map(\.frame).reduce(into: CGRect.null) { $0 = $0.union($1) }
        let scale = NSScreen.screens.first { $0.frame.contains(CGPoint(x: requested.midX, y: requested.midY)) }?.backingScaleFactor ?? 2
        let strip = Self.snappedToPixels(requested, scale: scale)
        let stripCG = CGRect(x: strip.minX, y: desktop.maxY - strip.maxY, width: strip.width, height: strip.height)
        guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: stripCG.midX, y: stripCG.midY)) }) else {
            throw CalibrationError.noDisplay
        }
        let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = stripCG.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        configuration.width = max(Int((strip.width * scale).rounded()), 1)
        configuration.height = max(Int((strip.height * scale).rounded()), 1)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        let image = try await Self.captureImage(filter: filter, configuration: configuration)
        guard let bitmap = RGBABitmap(image) else { throw CalibrationError.noImage }
        // The image is `height` device pixels tall for `strip.height` points.
        return (CapturedStrip(bitmap: bitmap, scale: CGFloat(image.height) / strip.height), strip)
    }

    /// `rect` grown outward to whole device pixels at `scale`.
    nonisolated static func snappedToPixels(_ rect: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0 else { return rect }
        let minX = (rect.minX * scale).rounded(.down) / scale
        let minY = (rect.minY * scale).rounded(.down) / scale
        let maxX = (rect.maxX * scale).rounded(.up) / scale
        let maxY = (rect.maxY * scale).rounded(.up) / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func currentShareableContent() async throws -> SCShareableContent {
        if let shareableContent {
            return shareableContent
        }
        let content: SCShareableContent = try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(throwing: CalibrationError.noDisplay)
                }
            }
        }
        shareableContent = content
        return content
    }

    private static func captureImage(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: CalibrationError.noImage)
                }
            }
        }
    }

    private func store(_ offset: CGFloat, for key: Key) {
        if cache[key] == nil {
            cacheOrder.append(key)
            if cacheOrder.count > Self.cacheLimit {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
        }
        cache[key] = offset
    }

    private static func log(_ background: HostBackground, request: BackgroundRequest) {
        guard CotabbyLogger.suggestion.logLevel <= .debug else { return }
        func hex(_ pixel: RGBABitmap.Pixel) -> String {
            String(format: "%02X%02X%02X", Int(pixel.red * 255), Int(pixel.green * 255), Int(pixel.blue * 255))
        }
        CotabbyLogger.suggestion.debug(
            "Host background measured",
            metadata: [
                "stage": .string("background-measurement"),
                "caret_line": .string(hex(background.caretLine)),
                "next_line": .string(hex(background.nextLine)),
                "identity": .stringConvertible(request.focusedInputIdentityKey)
            ]
        )
    }

    private static func log(_ analysis: Analysis, request: Request, elapsedMilliseconds: Int) {
        guard CotabbyLogger.suggestion.logLevel <= .debug else { return }
        CotabbyLogger.suggestion.debug(
            "Host baseline calibration",
            metadata: [
                "stage": .string("baseline-calibration"),
                "outcome": .string(analysis.baselineAccepted ? "measured" : "rejected"),
                "body_rows": .stringConvertible(analysis.bodyRows),
                "measured": .stringConvertible(Double(analysis.baselineOffset)),
                "policy": .stringConvertible(Double(request.policyOffset)),
                "caret_h": .stringConvertible(Double(request.caretRect.height)),
                "line_top": .stringConvertible(request.key.lineTop),
                "analysis_ms": .stringConvertible(elapsedMilliseconds)
            ]
        )
        guard analysis.typefaceAttempted else { return }
        // Pulled out of the literal below: a dozen interpolated entries in one dictionary is more
        // than the type checker resolves in reasonable time.
        let best = analysis.typefaceRanking.first
        let second = analysis.typefaceRanking.dropFirst().first
        let secondLabel = second.map { "\($0.familyName)@\($0.pointSize)" } ?? ""
        CotabbyLogger.suggestion.debug(
            "Host typeface match",
            metadata: [
                "stage": .string("typeface-match"),
                "outcome": .string(analysis.typefaceMatch == nil ? "none" : "matched"),
                "font": .string(analysis.typefaceMatch?.fontName ?? ""),
                "score": .stringConvertible(analysis.typefaceMatch?.score ?? 0),
                "runner_up": .stringConvertible(analysis.typefaceMatch?.runnerUpScore ?? 0),
                "system_score": .stringConvertible(analysis.typefaceMatch?.systemScore ?? -1),
                "size": .stringConvertible(Double(request.pointSize)),
                "size_fit": .stringConvertible(Double(analysis.typefaceMatch?.pointSize ?? 0)),
                "best_font": .string(best?.fontName ?? ""),
                "best_size": .stringConvertible(Double(best?.pointSize ?? 0)),
                "best_score": .stringConvertible(best?.score ?? 0),
                "second": .string(secondLabel),
                "text_len": .stringConvertible(request.lineText?.count ?? 0),
                "analysis_ms": .stringConvertible(elapsedMilliseconds)
            ]
        )
    }

    enum CalibrationError: Error {
        case noDisplay
        case noImage
    }
}
