import CoreGraphics
import Foundation

/// File overview:
/// Finds the text baseline in a small bitmap of host text: the bottom edge of the letter bodies.
///
/// Accessibility only hands out caret and character boxes rounded to whole points, while web
/// engines lay lines out at fractional positions and snap the painted baseline to device pixels.
/// The difference is invisible to AX and worth a full device pixel on screen, so the host's own
/// pixels are the only source that can settle it. The analyzer is pure (bitmap in, row out) so the
/// detection rule is unit-tested against text rendered at a known baseline.
///
/// Rule: rows whose ink is at least `bodyThreshold` of the busiest row belong to the letter bodies
/// (x-height and ascenders); descenders, underlines and antialiasing fringes carry far less. The
/// baseline is the bottom edge of the last body row. Saturated pixels are ignored so a red spelling
/// squiggle, a blue link underline or a colored caret never pass as text.
enum InkBaselineAnalyzer {
    struct Measurement: Equatable {
        /// Device-pixel row index (from the top) of the first row below the letter bodies; the
        /// baseline sits on this edge.
        let baselineRow: Int
        let bodyTopRow: Int
        let inkPixelCount: Int
    }

    static let bodyThreshold = 0.35
    static let inkContrast = 0.22
    static let maximumSaturation = 0.35
    static let minimumInkPixels = 40
    static let minimumBodyRows = 3

    static func measure(_ image: CGImage) -> Measurement? {
        guard let pixels = RGBABitmap(image) else { return nil }
        return measure(pixels)
    }

    static func measure(_ bitmap: RGBABitmap) -> Measurement? {
        let width = bitmap.width
        let height = bitmap.height
        guard width > 0, height > 0 else { return nil }
        var luminance = [Double](repeating: 0, count: width * height)
        var saturation = [Double](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                let pixel = bitmap.pixel(column: column, row: row)
                let index = row * width + column
                luminance[index] = pixel.luminance
                let maxChannel = max(pixel.red, pixel.green, pixel.blue)
                let minChannel = min(pixel.red, pixel.green, pixel.blue)
                saturation[index] = maxChannel > 0 ? (maxChannel - minChannel) / maxChannel : 0
            }
        }
        let background = median(luminance)
        var rowInk = [Int](repeating: 0, count: height)
        var total = 0
        for row in 0..<height {
            var count = 0
            for column in 0..<width {
                let index = row * width + column
                if abs(luminance[index] - background) > inkContrast, saturation[index] < maximumSaturation {
                    count += 1
                }
            }
            rowInk[row] = count
            total += count
        }
        guard total >= minimumInkPixels, let peak = rowInk.max(), peak > 0 else { return nil }
        let bodyRows = rowInk.indices.filter { Double(rowInk[$0]) >= bodyThreshold * Double(peak) }
        guard bodyRows.count >= minimumBodyRows, let first = bodyRows.first, let last = bodyRows.last else {
            return nil
        }
        return Measurement(baselineRow: last + 1, bodyTopRow: first, inkPixelCount: total)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

/// 8-bit RGBA copy of a `CGImage`, so the analyzer reads pixels without caring about the source
/// image's byte order, alpha placement or row padding.
struct RGBABitmap {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(_ image: CGImage) {
        let imageWidth = image.width
        let imageHeight = image.height
        guard imageWidth > 0, imageHeight > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: imageWidth * imageHeight * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: imageWidth,
                height: imageHeight,
                bitsPerComponent: 8,
                bytesPerRow: imageWidth * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
            return true
        }
        guard drawn else { return nil }
        width = imageWidth
        height = imageHeight
        bytes = buffer
    }

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    struct Pixel {
        let red: Double
        let green: Double
        let blue: Double

        var luminance: Double { 0.299 * red + 0.587 * green + 0.114 * blue }
    }

    /// Channels in 0...1. Row 0 is the top of the image (CGContext bitmaps are stored top-down).
    func pixel(column: Int, row: Int) -> Pixel {
        let offset = (row * width + column) * 4
        return Pixel(
            red: Double(bytes[offset]) / 255,
            green: Double(bytes[offset + 1]) / 255,
            blue: Double(bytes[offset + 2]) / 255
        )
    }
}
