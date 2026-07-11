import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Captures the exact frontmost terminal window used by terminal OCR sources.
///
/// The returned ScreenCaptureKit window identifier is part of the source identity. That prevents
/// a slow OCR result from window A being injected after the user has moved to window B in the same
/// terminal process—a case a bundle-id-only stale check cannot distinguish.
struct TerminalWindowCapture: @unchecked Sendable {
    struct Descriptor: Equatable, Sendable {
        let windowID: CGWindowID
        let windowFrame: CGRect
        let pid: Int32
        let bundleIdentifier: String
        let applicationName: String
        let title: String?
    }

    let descriptor: Descriptor
    /// Global Core Graphics coordinates for the pixels in `image`.
    let region: CGRect
    let image: CGImage
}

enum TerminalWindowCaptureError: LocalizedError {
    case screenRecordingPermissionMissing
    case noVisibleWindow(Int32)
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionMissing:
            return "Screen Recording permission is required for terminal OCR."
        case let .noVisibleWindow(pid):
            return "No visible terminal window was found for process \(pid)."
        case let .captureFailed(message):
            return "Terminal screenshot failed: \(message)"
        }
    }
}

struct TerminalWindowScreenshotService {
    /// `preferredRegion` is a global CG rect, normally an embedded terminal pane. Dedicated
    /// terminals pass nil and capture their whole window so OCR can verify Claude Code chrome.
    func capture(
        pid: Int32,
        bundleIdentifier: String,
        applicationName: String,
        preferredRegion: CGRect? = nil
    ) async throws -> TerminalWindowCapture {
        guard CGPreflightScreenCaptureAccess() else {
            throw TerminalWindowCaptureError.screenRecordingPermissionMissing
        }

        let content = try await shareableContent()
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid_t(pid) && $0.isOnScreen
        }
        guard let window = candidates.first(where: \.isActive) ?? candidates.first else {
            throw TerminalWindowCaptureError.noVisibleWindow(pid)
        }

        let region = (preferredRegion?.intersection(window.frame)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? window.frame
        let localRegion = CGRect(
            x: region.minX - window.frame.minX,
            y: region.minY - window.frame.minY,
            width: region.width,
            height: region.height
        )
        let scale = backingScaleFactor(forCoreGraphicsRect: region)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = localRegion
        configuration.width = max(Int((localRegion.width * scale).rounded(.up)), 1)
        configuration.height = max(Int((localRegion.height * scale).rounded(.up)), 1)
        configuration.showsCursor = false

        let image = try await captureImage(
            filter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration
        )
        return TerminalWindowCapture(
            descriptor: .init(
                windowID: window.windowID,
                windowFrame: window.frame,
                pid: pid,
                bundleIdentifier: bundleIdentifier,
                applicationName: applicationName,
                title: window.title
            ),
            region: region,
            image: image
        )
    }

    private func shareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                if let error {
                    continuation.resume(throwing: TerminalWindowCaptureError.captureFailed(error.localizedDescription))
                } else if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(throwing: TerminalWindowCaptureError.captureFailed("No shareable content."))
                }
            }
        }
    }

    private func captureImage(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: TerminalWindowCaptureError.captureFailed(error.localizedDescription))
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: TerminalWindowCaptureError.captureFailed("No image returned."))
                }
            }
        }
    }

    private func backingScaleFactor(forCoreGraphicsRect rect: CGRect) -> CGFloat {
        let appKitRect = AXHelper.cocoaRect(fromAccessibilityRect: rect)
        let point = CGPoint(x: appKitRect.midX, y: appKitRect.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(point) })?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }
}
