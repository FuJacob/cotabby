import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// File overview:
/// Reads a small region of the host's own pixels through ScreenCaptureKit, for the services that
/// measure what Accessibility cannot report (`HostBaselineCalibrator`, `PixelCaretLocator`).
///
/// Captures exclude Cotabby's own windows, and an excluded window comes back black, so a ghost on
/// screen is never mistaken for host text and never read through either. Callers check Screen
/// Recording permission themselves before asking: this type only captures.
@MainActor
final class HostPixelCapture {
    struct Capture: Sendable {
        let bitmap: RGBABitmap
        /// Device pixels per point in the capture.
        let scale: CGFloat
        /// The region actually captured, in global Cocoa coordinates: the requested one grown
        /// outward to whole device pixels. Rows and columns of `bitmap` map back through this.
        let region: CGRect
    }

    enum CaptureError: Error {
        case noDisplay
        case noImage
    }

    /// Enumerating shareable content costs tens of milliseconds, so the first answer is reused.
    private var shareableContent: SCShareableContent?

    // Xcode 26.0-26.3 emits an isolated deinit for a stored-property @MainActor class whose
    // teardown double-frees when a test-scoped instance deallocates ("pointer being freed was not
    // allocated"). Nothing here needs main-actor cleanup, so a nonisolated deinit is equivalent.
    nonisolated deinit {}

    /// Captures `requested` snapped outward to the display's pixel grid. A region edge on a
    /// fractional pixel makes ScreenCaptureKit resample the whole image (a sub-pixel phase that
    /// drifts across the width): measured 2026-09-10 on Chrome's address bar, glyph stems came back
    /// four pixels wide instead of three and no candidate face correlated above 0.3, while a
    /// pixel-aligned screenshot of the same text scored 0.95. Whole pixels in, the copy is exact.
    func capture(_ requested: CGRect) async throws -> Capture {
        let content = try await currentShareableContent()
        let desktop = NSScreen.screens.map(\.frame).reduce(into: CGRect.null) { $0 = $0.union($1) }
        let scale = NSScreen.screens.first { $0.frame.contains(CGPoint(x: requested.midX, y: requested.midY)) }?.backingScaleFactor ?? 2
        let region = Self.snappedToPixels(requested, scale: scale)
        let regionCG = CGRect(x: region.minX, y: desktop.maxY - region.maxY, width: region.width, height: region.height)
        guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: regionCG.midX, y: regionCG.midY)) }) else {
            throw CaptureError.noDisplay
        }
        let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = regionCG.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        configuration.width = max(Int((region.width * scale).rounded()), 1)
        configuration.height = max(Int((region.height * scale).rounded()), 1)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        let image = try await Self.captureImage(filter: filter, configuration: configuration)
        guard let bitmap = RGBABitmap(image) else { throw CaptureError.noImage }
        // The image is `height` device pixels tall for `region.height` points.
        return Capture(bitmap: bitmap, scale: CGFloat(image.height) / region.height, region: region)
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
                    continuation.resume(throwing: CaptureError.noDisplay)
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
                    continuation.resume(throwing: CaptureError.noImage)
                }
            }
        }
    }

    // MARK: - Capture dumps (developer diagnostics)

    /// Developer builds only: with `defaults write <bundle> cotabbyDumpCalibrationStrips -bool YES`,
    /// every capture is written as a PNG plus a JSON sidecar under `strips/` in the debug artifact
    /// directory, so a measurement that went wrong on a live capture can be re-run offline on
    /// exactly the pixels it saw. Off by default. The switch itself, compiled out of shipping
    /// builds, lives in `CotabbyDebugArtifacts.dumpsCalibrationStrips`.
    static var dumpsCaptures: Bool { CotabbyDebugArtifacts.dumpsCalibrationStrips }

    /// Writes `<prefix>-<milliseconds>.png` and `.json` into the strips folder, owner-only, then
    /// drops all but the newest `CotabbyDebugArtifacts.maximumCalibrationCaptures` captures: the
    /// sidecar carries the caret line's text, and a session left dumping writes one pair per
    /// capture. The sidecar is written even when the PNG cannot be encoded: it still says what was
    /// asked of the capture.
    nonisolated static func dump(_ bitmap: RGBABitmap, prefix: String, sidecar: [String: Any]) {
        guard let folder = CotabbyDebugArtifacts.preparedDirectory([CotabbyDebugArtifacts.stripsFolderName]) else { return }
        defer {
            CotabbyDebugArtifacts.evictOldCaptures(in: folder, keeping: CotabbyDebugArtifacts.maximumCalibrationCaptures)
        }
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        if let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: bitmap.width, pixelsHigh: bitmap.height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: bitmap.width * 4, bitsPerPixel: 32
        ), let data = representation.bitmapData {
            bitmap.bytes.withUnsafeBufferPointer { bytes in
                if let base = bytes.baseAddress {
                    data.update(from: base, count: bytes.count)
                }
            }
            if let png = representation.representation(using: .png, properties: [:]) {
                CotabbyDebugArtifacts.writePrivateFile(png, to: folder.appendingPathComponent("\(prefix)-\(stamp).png"))
            }
        }
        if let json = try? JSONSerialization.data(withJSONObject: sidecar) {
            CotabbyDebugArtifacts.writePrivateFile(json, to: folder.appendingPathComponent("\(prefix)-\(stamp).json"))
        }
    }
}
