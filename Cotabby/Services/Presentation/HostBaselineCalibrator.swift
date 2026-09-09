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
    /// Identifies the thing being measured: the distance from the caret box's top to the baseline
    /// the host paints its text on.
    ///
    /// Deliberately NOT keyed by the caret's line. That offset is a property of the field's font
    /// and line box, so it is the same on every line, and keying by line made Cotabby re-measure
    /// each line independently from screen pixels. Those measurements disagree by a fraction of a
    /// point (measured live in Obsidian: 15.0 on most lines, 14.5 and 11.0 on others), so the ghost
    /// sat visibly higher on some lines than others, and each new line briefly rendered on the
    /// policy guess before its own measurement replaced it. A field whose lines genuinely differ in
    /// size still separates here, because `caretHeight` and `fontPointSize` are part of the key.
    struct Key: Hashable {
        let focusedInputIdentityKey: UInt64
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

        init(
            key: Key,
            caretRect: CGRect,
            contentLeft: CGFloat?,
            policyOffset: CGFloat,
            lineText: String? = nil,
            pointSize: CGFloat = 0,
            matchTypeface: Bool = false
        ) {
            self.key = key
            self.caretRect = caretRect
            self.contentLeft = contentLeft
            self.policyOffset = policyOffset
            self.lineText = lineText
            self.pointSize = pointSize
            self.matchTypeface = matchTypeface
        }
    }

    /// Typeface knowledge is per field and size, not per line.
    struct TypefaceKey: Hashable {
        let focusedInputIdentityKey: UInt64
        let fontPointSize: Int
    }

    struct Calibration: Equatable {
        /// Measured baseline offset below the caret box top.
        let baselineOffset: CGFloat
        /// PostScript name of the face the host's pixels matched, when one was asked for and found.
        let typefaceName: String?
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
    /// Measurements collected per key before the median is considered settled. Small because the
    /// readings agree in the overwhelming majority of cases; the point is only to outvote an
    /// occasional stray one, not to average noise away.
    static let maximumSamples = 5

    /// Median of `samples`, recomputed on every store: the value callers actually render with.
    private var cache: [Key: CGFloat] = [:]
    /// Individual accepted measurements per key. A median over several lines is what makes one
    /// stray reading harmless — the acceptance window is +/-4pt (wide enough for Safari's loose
    /// CSS line heights), so a single bad strip can be accepted, and with one measurement per
    /// field it would otherwise define that field's baseline for the whole session.
    private var samples: [Key: [CGFloat]] = [:]
    private var cacheOrder: [Key] = []
    private var typefaces: [TypefaceKey: String] = [:]
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

    /// The face the host's pixels matched for this field and size, if already known.
    func cachedTypeface(for key: TypefaceKey) -> String? {
        typefaces[key]
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
                let captured = try await self.capture(region)
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
        let typefaceKey = TypefaceKey(focusedInputIdentityKey: key.focusedInputIdentityKey, fontPointSize: key.fontPointSize)
        let needsTypeface = request.matchTypeface && typefaces[typefaceKey] == nil
        let sampleCount = samples[key]?.count ?? 0
        guard sampleCount < Self.maximumSamples || needsTypeface, permissionCheck() else { return }
        if waiters[key] != nil {
            waiters[key]?.append(completion)
            return
        }
        guard let strip = Self.captureStrip(caretRect: request.caretRect, contentLeft: request.contentLeft) else { return }
        waiters[key] = [completion]
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let captured = try await self.capture(strip)
                let knownTypeface = self.typefaces[typefaceKey]
                let started = Date()
                // Pixel analysis (row/column profiles, candidate renderings) runs off the main actor
                // so a focus poll never waits on it; only the bookkeeping below touches state.
                let analysis = await Task.detached(priority: .userInitiated) {
                    Self.analyze(captured, strip: strip, request: request, knownTypeface: knownTypeface)
                }.value
                let listeners = self.waiters.removeValue(forKey: key) ?? []
                guard let analysis else { return }
                if analysis.baselineAccepted {
                    self.store(analysis.baselineOffset, for: key)
                }
                if let match = analysis.typefaceMatch, self.typefaces[typefaceKey] == nil {
                    self.typefaces[typefaceKey] = match.fontName
                }
                Self.log(analysis, request: request, elapsedMilliseconds: Int(Date().timeIntervalSince(started) * 1000))
                guard analysis.baselineAccepted || analysis.typefaceName != nil else { return }
                let calibration = Calibration(
                    baselineOffset: analysis.baselineAccepted ? analysis.baselineOffset : (self.cache[key] ?? request.policyOffset),
                    typefaceName: analysis.typefaceName
                )
                for listener in listeners {
                    listener(calibration)
                }
            } catch {
                self.waiters.removeValue(forKey: key)
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
        /// A face found in this capture (nil when known already or not asked for / not found).
        let typefaceMatch: TypefaceMatcher.Match?
        /// The face to report: freshly matched, or the one already known for the field.
        let typefaceName: String?
        let typefaceAttempted: Bool
    }

    /// Reads the baseline (and, when asked, the typeface) out of the captured strip. Pure; nil when
    /// the strip held no usable text.
    private nonisolated static func analyze(
        _ captured: CapturedStrip,
        strip: CGRect,
        request: Request,
        knownTypeface: String?
    ) -> Analysis? {
        guard let measurement = InkBaselineAnalyzer.measure(captured.bitmap) else { return nil }
        let measuredPoints = CGFloat(measurement.baselineRow) / captured.scale
        let offset = baselineOffset(fromCaretTop: request.caretRect.maxY, stripTop: strip.maxY, measured: measuredPoints)
        let accepted = accepts(measured: offset, policy: request.policyOffset)
        var match: TypefaceMatcher.Match?
        var attempted = false
        if request.matchTypeface, knownTypeface == nil, let lineText = request.lineText, request.pointSize > 0 {
            attempted = true
            match = TypefaceMatcher.match(
                TypefaceMatcher.Input(
                    strip: captured.bitmap,
                    scale: captured.scale,
                    caretColumn: (request.caretRect.minX - strip.minX) * captured.scale,
                    baselineRow: CGFloat(measurement.baselineRow),
                    text: lineText,
                    pointSize: request.pointSize,
                    candidates: TypefaceMatcher.defaultCandidates(pointSize: request.pointSize)
                )
            )
        }
        return Analysis(
            baselineOffset: offset,
            baselineAccepted: accepted,
            typefaceMatch: match,
            typefaceName: match?.fontName ?? (request.matchTypeface ? knownTypeface : nil),
            typefaceAttempted: attempted
        )
    }

    // MARK: - Pure geometry

    /// The screen strip to measure, in Cocoa coordinates: host text left of the caret, the caret
    /// line's box plus a little vertical slack. Nil when there is no room for enough text.
    nonisolated static func captureStrip(caretRect: CGRect, contentLeft: CGFloat?) -> CGRect? {
        let right = caretRect.minX - caretGap
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

    // MARK: - Capture

    private func capture(_ strip: CGRect) async throws -> CapturedStrip {
        let content = try await currentShareableContent()
        let desktop = NSScreen.screens.map(\.frame).reduce(into: CGRect.null) { $0 = $0.union($1) }
        let stripCG = CGRect(x: strip.minX, y: desktop.maxY - strip.maxY, width: strip.width, height: strip.height)
        guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: stripCG.midX, y: stripCG.midY)) }) else {
            throw CalibrationError.noDisplay
        }
        let scale = NSScreen.screens.first { $0.frame.contains(CGPoint(x: strip.midX, y: strip.midY)) }?.backingScaleFactor ?? 2
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
        return CapturedStrip(bitmap: bitmap, scale: CGFloat(image.height) / strip.height)
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

    /// Records one accepted measurement and republishes the key's median.
    ///
    /// The median (rather than the latest reading) is what keeps the ghost still: later samples can
    /// only move the rendered baseline when they genuinely outvote the earlier ones, so a lone
    /// outlier never shifts the text, and an outlier that happens to arrive first is corrected by
    /// the next two rather than defining the field.
    private func store(_ offset: CGFloat, for key: Key) {
        if samples[key] == nil {
            cacheOrder.append(key)
            if cacheOrder.count > Self.cacheLimit {
                let evicted = cacheOrder.removeFirst()
                cache.removeValue(forKey: evicted)
                samples.removeValue(forKey: evicted)
            }
        }
        samples[key, default: []].append(offset)
        cache[key] = Self.median(of: samples[key] ?? [offset])
    }

    /// Lower-middle element of the sorted samples, so the result is deterministic for an even count.
    static func median(of values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
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
                "measured": .stringConvertible(Double(analysis.baselineOffset)),
                "policy": .stringConvertible(Double(request.policyOffset)),
                "caret_h": .stringConvertible(Double(request.caretRect.height)),
                "analysis_ms": .stringConvertible(elapsedMilliseconds)
            ]
        )
        guard analysis.typefaceAttempted else { return }
        CotabbyLogger.suggestion.debug(
            "Host typeface match",
            metadata: [
                "stage": .string("typeface-match"),
                "outcome": .string(analysis.typefaceMatch == nil ? "none" : "matched"),
                "font": .string(analysis.typefaceMatch?.fontName ?? ""),
                "score": .stringConvertible(analysis.typefaceMatch?.score ?? 0),
                "runner_up": .stringConvertible(analysis.typefaceMatch?.runnerUpScore ?? 0),
                "size": .stringConvertible(Double(request.pointSize)),
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
