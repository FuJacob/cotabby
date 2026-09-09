import AppKit
import CoreGraphics
import Foundation

/// File overview:
/// Identifies the typeface a host painted from the host's own pixels, for fields that name no
/// font and answer no width query.
///
/// Chromium contenteditables (Gmail, Slack, Notion, Docs-style editors) report a font size and
/// nothing else: no family, and `AXBoundsForRange` returns an empty rect, so the width match in
/// `GhostFontResolver` has nothing to work with and the ghost falls back to the system face. The
/// text left of the caret is on screen, though, and its text is known. Rendering that text in each
/// candidate face, right-aligned at the caret on the measured baseline, and correlating the column
/// ink profile with the host's strip picks the face the host used. Pure (bitmap in, name out) so it
/// is tested against strips rendered in known faces.
enum TypefaceMatcher {
    struct Input {
        /// Host pixels, row 0 at the top.
        let strip: RGBABitmap
        /// Device pixels per point.
        let scale: CGFloat
        /// Column (px) in the strip where the caret sits; the text ends there.
        let caretColumn: CGFloat
        /// Row (px) of the host's text baseline in the strip.
        let baselineRow: CGFloat
        /// The text immediately before the caret on its visual line, or as much of it as is known.
        let text: String
        let pointSize: CGFloat
        let candidates: [NSFont]
    }

    struct Match: Equatable {
        let fontName: String
        let familyName: String
        let score: Double
        let runnerUpScore: Double
    }

    /// Lowest normalized correlation accepted as "this is the face".
    static let minimumScore = 0.88
    /// Smallest lead over the next candidate required, so two faces that fit equally well (Arial
    /// and Helvetica share advances) resolve to the earlier, more common one only when it also
    /// fits the glyph shapes better.
    static let minimumMargin = 0.015
    /// Horizontal slack for the caret column, which Accessibility rounds to whole points.
    static let maximumLagPixels = 3
    /// Columns right of the caret and the caret itself are never compared.
    static let caretGapPixels = 2
    /// Shorter text is too little evidence.
    static let minimumTextLength = 3

    /// Families tried, most common first. The system face is always tried too.
    static let candidateFamilies: [String] = [
        "Helvetica", "Arial", "Helvetica Neue", "Georgia", "Times New Roman", "Verdana",
        "Menlo", "Courier New", "Trebuchet MS", "Avenir Next", "SF Mono"
    ]

    static func defaultCandidates(pointSize: CGFloat) -> [NSFont] {
        var fonts: [NSFont] = [NSFont.systemFont(ofSize: pointSize)]
        for family in candidateFamilies {
            if let font = GhostFontResolver.font(family: family, size: pointSize) {
                fonts.append(font)
            }
        }
        return fonts
    }

    static func match(_ input: Input) -> Match? {
        guard input.text.count >= minimumTextLength, input.caretColumn > 8, !input.candidates.isEmpty else { return nil }
        let hostProfile = InkProfile.columns(of: input.strip)
        let variants = textVariants(HostLineText.tail(of: input.text))
        var scored: [(font: NSFont, score: Double)] = []
        for candidate in input.candidates {
            var best = -1.0
            for variant in variants {
                guard let rendered = render(variant, font: candidate, input: input) else { continue }
                let candidateProfile = InkProfile.darkInkColumns(of: rendered)
                let score = correlate(host: hostProfile, candidate: candidateProfile, input: input, rendered: rendered)
                best = max(best, score)
            }
            scored.append((candidate, best))
        }
        scored.sort { $0.score > $1.score }
        guard let winner = scored.first, winner.score >= minimumScore else { return nil }
        let runnerUp = scored.dropFirst().first?.score ?? -1
        guard winner.score - runnerUp >= minimumMargin || scored.dropFirst().first?.font.familyName == winner.font.familyName else {
            return nil
        }
        return Match(
            fontName: winner.font.fontName,
            familyName: winner.font.familyName ?? winner.font.fontName,
            score: winner.score,
            runnerUpScore: runnerUp
        )
    }

    /// The full text and its last two words: when the caret sits shortly after a soft wrap the
    /// strip holds only the tail, and the shorter variant is what actually appears on screen.
    private static func textVariants(_ text: String) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        var variants = [text]
        if words.count > 2 {
            variants.append(words.suffix(2).joined(separator: " "))
        }
        return variants
    }

    /// Renders `text` right-aligned so its advance ends at the caret column, on the host's baseline,
    /// into a bitmap the size of the strip. Black on white; only the column profile is used.
    private static func render(_ text: String, font: NSFont, input: Input) -> RGBABitmap? {
        let width = input.strip.width
        let height = input.strip.height
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 255, count: width * height * 4)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        let line = CTLineCreateWithAttributedString(attributed)
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: input.scale, y: input.scale)
            let penX = input.caretColumn / input.scale - advance
            let baselineY = (CGFloat(height) - input.baselineRow) / input.scale
            context.textPosition = CGPoint(x: penX, y: baselineY)
            CTLineDraw(line, context)
            return true
        }
        guard drawn else { return nil }
        return RGBABitmap(width: width, height: height, bytes: buffer)
    }

    /// Normalized cross-correlation of the two column profiles over the columns the candidate
    /// rendering covers, maximized over a few pixels of horizontal lag.
    private static func correlate(host: [Double], candidate: [Double], input: Input, rendered: RGBABitmap) -> Double {
        // The strip usually ends a little before the caret, so the caret column can lie past the
        // bitmap's right edge; never index beyond either profile.
        let end = min(Int(input.caretColumn) - caretGapPixels, host.count, candidate.count)
        guard end > 8 else { return -1 }
        // Compare only where the candidate put ink (its left edge), so a strip with more text to the
        // left than the variant does not penalize a correct face.
        let firstInk = candidate.firstIndex(where: { $0 > 0.5 }) ?? 0
        let start = max(0, firstInk - 2)
        guard end - start >= 12 else { return -1 }
        var best = -1.0
        for lag in -maximumLagPixels...maximumLagPixels {
            var sumH = 0.0, sumC = 0.0, count = 0.0
            for column in start..<end {
                let hostColumn = column + lag
                guard hostColumn >= 0, hostColumn < host.count else { continue }
                sumH += host[hostColumn]
                sumC += candidate[column]
                count += 1
            }
            guard count > 0 else { continue }
            let meanH = sumH / count
            let meanC = sumC / count
            var numerator = 0.0, varianceH = 0.0, varianceC = 0.0
            for column in start..<end {
                let hostColumn = column + lag
                guard hostColumn >= 0, hostColumn < host.count else { continue }
                let deltaH = host[hostColumn] - meanH
                let deltaC = candidate[column] - meanC
                numerator += deltaH * deltaC
                varianceH += deltaH * deltaH
                varianceC += deltaC * deltaC
            }
            guard varianceH > 0, varianceC > 0 else { continue }
            best = max(best, numerator / (varianceH * varianceC).squareRoot())
        }
        return best
    }
}

/// Contrast-weighted ink profiles of a bitmap: how much each column differs from the background,
/// ignoring saturated pixels (colored carets, squiggles, link underlines). Integer arithmetic over
/// the raw bytes: a match renders a dozen candidate faces and the work must stay well under the
/// model's own latency even in debug builds.
enum InkProfile {
    /// Saturation limit as (max - min) * 100 / max, in percent.
    static let maximumSaturationPercent = 35

    static func columns(of bitmap: RGBABitmap) -> [Double] {
        let width = bitmap.width
        let background = backgroundLuminance(of: bitmap)
        var profile = [Int](repeating: 0, count: width)
        bitmap.bytes.withUnsafeBufferPointer { bytes in
            for row in 0..<bitmap.height {
                let rowStart = row * width * 4
                for column in 0..<width {
                    let offset = rowStart + column * 4
                    let red = Int(bytes[offset]), green = Int(bytes[offset + 1]), blue = Int(bytes[offset + 2])
                    let maxChannel = max(red, green, blue)
                    let minChannel = min(red, green, blue)
                    if maxChannel > 0, (maxChannel - minChannel) * 100 / maxChannel >= maximumSaturationPercent { continue }
                    profile[column] += abs(luminance(red, green, blue) - background)
                }
            }
        }
        return profile.map { Double($0) / 1000 }
    }

    /// Profile of a rendering known to be dark ink on a white ground (the candidate faces): no
    /// background estimate or saturation test needed.
    static func darkInkColumns(of bitmap: RGBABitmap) -> [Double] {
        let width = bitmap.width
        var profile = [Int](repeating: 0, count: width)
        bitmap.bytes.withUnsafeBufferPointer { bytes in
            for row in 0..<bitmap.height {
                let rowStart = row * width * 4
                for column in 0..<width {
                    profile[column] += 255 - Int(bytes[rowStart + column * 4 + 1])
                }
            }
        }
        return profile.map { Double($0) / 255 }
    }

    /// Luminance scaled by 1000 (0...255000).
    private static func luminance(_ red: Int, _ green: Int, _ blue: Int) -> Int {
        (299 * red + 587 * green + 114 * blue)
    }

    /// Median luminance (scaled by 1000) from a 256-bin histogram of the green channel weighted
    /// luminance, so no per-pixel allocation or sort is needed.
    static func backgroundLuminance(of bitmap: RGBABitmap) -> Int {
        var histogram = [Int](repeating: 0, count: 256)
        let width = bitmap.width
        bitmap.bytes.withUnsafeBufferPointer { bytes in
            for row in 0..<bitmap.height {
                let rowStart = row * width * 4
                for column in 0..<width {
                    let offset = rowStart + column * 4
                    let lum = luminance(Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])) / 1000
                    histogram[min(max(lum, 0), 255)] += 1
                }
            }
        }
        let total = bitmap.width * bitmap.height
        var seen = 0
        for (value, count) in histogram.enumerated() {
            seen += count
            if seen * 2 >= total { return value * 1000 }
        }
        return 0
    }
}

/// The part of the preceding text that can be on the caret's visual line: after the last hard
/// line break, bounded so long paragraphs cost nothing.
enum HostLineText {
    static let maximumLength = 48

    static func tail(of precedingText: String) -> String {
        let afterBreak: Substring
        if let breakIndex = precedingText.lastIndex(where: { $0.isNewline }) {
            afterBreak = precedingText[precedingText.index(after: breakIndex)...]
        } else {
            afterBreak = precedingText[...]
        }
        return String(afterBreak.suffix(maximumLength))
    }
}
