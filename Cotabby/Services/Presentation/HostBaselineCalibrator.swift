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
    /// Callers waiting on a measurement in flight, per key. A present that arrives while the
    /// generation-time prewarm is still capturing joins its measurement instead of being dropped.
    private var waiters: [Key: [@MainActor (CGFloat) -> Void]] = [:]
    private var shareableContent: SCShareableContent?

    private let permissionCheck: () -> Bool

    init(permissionCheck: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() }) {
        self.permissionCheck = permissionCheck
    }

    /// The measured baseline offset from the caret box top for this line, if already known.
    func cachedOffset(for key: Key) -> CGFloat? {
        cache[key]
    }

    /// Starts a measurement for `request` unless one is cached, or joins the one already in flight
    /// for the same key. `completion` runs on the main actor only when a fresh, accepted measurement
    /// arrives.
    func calibrate(_ request: Request, completion: @escaping @MainActor (CGFloat) -> Void) {
        let key = request.key
        guard cache[key] == nil, permissionCheck() else { return }
        if waiters[key] != nil {
            waiters[key]?.append(completion)
            return
        }
        guard let strip = Self.captureStrip(caretRect: request.caretRect, contentLeft: request.contentLeft) else { return }
        waiters[key] = [completion]
        Task { @MainActor [weak self] in
            guard let self else { return }
            let pending = self.waiters.removeValue(forKey: key) ?? []
            do {
                let measured = try await self.measureBaseline(in: strip)
                let offset = Self.baselineOffset(fromCaretTop: request.caretRect.maxY, stripTop: strip.maxY, measured: measured)
                // Anyone who asked while the capture ran is answered too.
                let listeners = pending + (self.waiters.removeValue(forKey: key) ?? [])
                guard Self.accepts(measured: offset, policy: request.policyOffset) else {
                    Self.log("rejected", request: request, measured: offset)
                    return
                }
                self.store(offset, for: key)
                Self.log("measured", request: request, measured: offset)
                for listener in listeners {
                    listener(offset)
                }
            } catch {
                self.waiters.removeValue(forKey: key)
                CotabbyLogger.suggestion.debug("Baseline calibration failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Pure geometry

    /// The screen strip to measure, in Cocoa coordinates: host text left of the caret, the caret
    /// line's box plus a little vertical slack. Nil when there is no room for enough text.
    static func captureStrip(caretRect: CGRect, contentLeft: CGFloat?) -> CGRect? {
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
    static func baselineOffset(fromCaretTop caretTop: CGFloat, stripTop: CGFloat, measured: CGFloat) -> CGFloat {
        measured - (stripTop - caretTop)
    }

    static func accepts(measured: CGFloat, policy: CGFloat) -> Bool {
        abs(measured - policy) <= maximumCorrection
    }

    // MARK: - Capture

    private func measureBaseline(in strip: CGRect) async throws -> CGFloat {
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
        guard let measurement = InkBaselineAnalyzer.measure(image) else {
            throw CalibrationError.noText
        }
        // The image is `height` device pixels tall for `strip.height` points; the measured edge row
        // converts back to points below the strip's top.
        let pointsPerPixel = strip.height / CGFloat(image.height)
        return CGFloat(measurement.baselineRow) * pointsPerPixel
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

    private static func log(_ outcome: String, request: Request, measured: CGFloat) {
        guard CotabbyLogger.suggestion.logLevel <= .debug else { return }
        CotabbyLogger.suggestion.debug(
            "Host baseline calibration",
            metadata: [
                "stage": .string("baseline-calibration"),
                "outcome": .string(outcome),
                "measured": .stringConvertible(Double(measured)),
                "policy": .stringConvertible(Double(request.policyOffset)),
                "caret_h": .stringConvertible(Double(request.caretRect.height)),
                "line_top": .stringConvertible(request.key.lineTop)
            ]
        )
    }

    enum CalibrationError: Error {
        case noDisplay
        case noImage
        case noText
    }
}
