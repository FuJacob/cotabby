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
/// Lifecycle: owned by `OverlayController`, one per app. Measurements are cached per field and
/// paragraph text so the many presentations of one suggestion (stability-gate re-presents, the
/// return from a card) reuse one capture; a keystroke changes the text, so the next generation
/// measures again. Captures exclude Cotabby's own windows so a ghost already on screen is never
/// mistaken for host text.
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

        var cacheKey: String {
            let frame = "\(Int(runFrame.minX.rounded())),\(Int(runFrame.maxY.rounded())),\(Int(runFrame.width.rounded()))"
            return "\(focusedInputIdentityKey)|\(frame)|\(paragraphTextBeforeCaret.hashValue)"
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
    }

    /// Points of slack captured around the run so a glyph touching the frame edge is not clipped.
    static let padding: CGFloat = 6
    /// Where the host draws its caret relative to the last glyph's ink: the advance ends about a
    /// side bearing past the ink, which is under a point at text sizes.
    static let inkToCaretGap: CGFloat = 0.75
    private static let cacheLimit = 8

    private var cache: [String: Measurement] = [:]
    private var cacheOrder: [String] = []
    private var failures: Set<String> = []
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
        let region = request.runFrame.insetBy(dx: -Self.padding, dy: -Self.padding)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let started = Date()
            var measurement: Measurement?
            var failure = "capture"
            do {
                let captured = try await self.capture(region)
                let analysis = await Task.detached(priority: .userInitiated) {
                    InkCaretAnalyzer.measure(captured.bitmap)
                }.value
                if let analysis {
                    measurement = Self.measurement(from: analysis, scale: captured.scale, region: region, request: request)
                    failure = measurement == nil ? "geometry" : ""
                } else {
                    failure = "no-ink"
                }
            } catch {
                failure = "capture: \(error.localizedDescription)"
            }
            let listeners = self.inFlight.removeValue(forKey: key) ?? []
            if let measurement {
                self.store(measurement, for: key)
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
            caretX = inkRight + inkToCaretGap + CGFloat(trailingSpaces) * request.spaceAdvance
        }
        guard caretX >= frame.minX - 1, caretX <= frame.maxX + request.spaceAdvance * 2 + 1 else { return nil }
        return Measurement(
            caretRect: CGRect(x: caretX, y: lineRect.minY, width: 2, height: lineBox),
            lineRect: lineRect,
            linePitch: pitch,
            lineIndex: lineIndex,
            lineCount: lineCount
        )
    }

    // MARK: - Capture

    private struct Captured {
        let bitmap: RGBABitmap
        let scale: CGFloat
    }

    private func capture(_ region: CGRect) async throws -> Captured {
        let content = try await currentShareableContent()
        let desktop = NSScreen.screens.map(\.frame).reduce(into: CGRect.null) { $0 = $0.union($1) }
        let regionCG = CGRect(x: region.minX, y: desktop.maxY - region.maxY, width: region.width, height: region.height)
        guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: regionCG.midX, y: regionCG.midY)) }) else {
            throw LocatorError.noDisplay
        }
        let scale = NSScreen.screens.first { $0.frame.contains(CGPoint(x: region.midX, y: region.midY)) }?.backingScaleFactor ?? 2
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
        return Captured(bitmap: bitmap, scale: CGFloat(image.height) / region.height)
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
        } else {
            metadata["reason"] = .string(failure)
        }
        CotabbyLogger.suggestion.debug(measurement == nil ? "Pixel caret unavailable" : "Pixel caret measured", metadata: metadata)
    }
}
