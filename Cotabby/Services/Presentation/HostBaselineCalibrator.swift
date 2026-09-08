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

    /// Widest strip of host text measured left of the caret.
    static let maximumStripWidth: CGFloat = 240
    /// Narrower strips hold too few glyphs for a trustworthy body-row profile.
    static let minimumStripWidth: CGFloat = 24
    /// Gap kept between the strip and the caret so the caret bar never counts as ink.
    static let caretGap: CGFloat = 2
    static let verticalPadding: CGFloat = 2
    /// A measurement further than this from the policy baseline is not the same text line (an
    /// underline, a squiggle, or a neighbouring line leaked in) and is rejected.
    static let maximumCorrection: CGFloat = 1.5
    private static let cacheLimit = 64

    private var cache: [Key: CGFloat] = [:]
    private var cacheOrder: [Key] = []
    private var typefaces: [TypefaceKey: String] = [:]
    /// Callers waiting on a measurement in flight, per key. A present that arrives while the
    /// generation-time prewarm is still capturing joins its measurement instead of being dropped.
    private var waiters: [Key: [@MainActor (Calibration) -> Void]] = [:]
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

    /// Starts a measurement for `request` unless one is cached, or joins the one already in flight
    /// for the same key. `completion` runs on the main actor only when a fresh, accepted measurement
    /// arrives.
    func calibrate(_ request: Request, completion: @escaping @MainActor (Calibration) -> Void) {
        let key = request.key
        let typefaceKey = TypefaceKey(focusedInputIdentityKey: key.focusedInputIdentityKey, fontPointSize: key.fontPointSize)
        let needsTypeface = request.matchTypeface && typefaces[typefaceKey] == nil
        guard cache[key] == nil || needsTypeface, permissionCheck() else { return }
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

    private func store(_ offset: CGFloat, for key: Key) {
        if cache[key] == nil {
            cacheOrder.append(key)
            if cacheOrder.count > Self.cacheLimit {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
        }
        cache[key] = offset
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
                "line_top": .stringConvertible(request.key.lineTop),
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
