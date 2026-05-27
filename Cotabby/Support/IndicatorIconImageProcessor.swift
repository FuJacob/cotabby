import AppKit
import Foundation

/// File overview:
/// Turns a user-picked image into a small, square PNG suitable for the field-edge activation
/// indicator. Keeping this pure and AppKit-only (no app state) keeps the aspect-fill math testable
/// and lets `SuggestionSettingsModel` stay focused on persistence.
enum IndicatorIconImageProcessor {
    /// Stored icons are tiny. 64px keeps the 20pt indicator crisp up to a 3x backing scale while
    /// staying small enough to live in UserDefaults without bloating the domain.
    static let defaultPixelSize = 64

    /// Decodes `imageData` and renders it into a square PNG `pixelSize` on a side, scaling the
    /// source to fill the square and center-cropping any overflow. Returns nil when the data is not
    /// a decodable image or a bitmap context cannot be created.
    static func squareIconPNGData(from imageData: Data, pixelSize: Int = defaultPixelSize) -> Data? {
        guard let image = NSImage(data: imageData), image.isValid else {
            return nil
        }
        return squareIconPNGData(from: image, pixelSize: pixelSize)
    }

    static func squareIconPNGData(from image: NSImage, pixelSize: Int = defaultPixelSize) -> Data? {
        let side = max(1, pixelSize)
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        representation.size = NSSize(width: side, height: side)

        guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
            return nil
        }

        let square = NSRect(x: 0, y: 0, width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(
            in: aspectFillRect(sourceSize: image.size, in: square),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        return representation.representation(using: .png, properties: [:])
    }

    /// Returns the rect to draw a `sourceSize` image into `destination` so it fully covers the
    /// destination while preserving aspect ratio, centering the cropped overflow. Falls back to the
    /// destination rect when the source has no area.
    static func aspectFillRect(sourceSize: NSSize, in destination: NSRect) -> NSRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return destination
        }

        let scale = max(destination.width / sourceSize.width, destination.height / sourceSize.height)
        let scaledWidth = sourceSize.width * scale
        let scaledHeight = sourceSize.height * scale

        return NSRect(
            x: destination.midX - scaledWidth / 2,
            y: destination.midY - scaledHeight / 2,
            width: scaledWidth,
            height: scaledHeight
        )
    }
}
