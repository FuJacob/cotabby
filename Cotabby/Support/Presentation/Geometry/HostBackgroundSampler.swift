import Foundation

/// File overview:
/// Reads a host field's painted background color out of a screen capture. The ghost's opaque row
/// bands (`GhostTextLayout.RowBand`) must match the field exactly or they show as a rectangle, so
/// the color is taken from the field's own pixels rather than from Accessibility (which exposes no
/// background) or the system appearance (a dark web page in light mode, Notes' paper, editor
/// themes). Pure so it can be unit-tested on synthetic bitmaps and run off the main actor.
enum HostBackgroundSampler {
    /// The most common color among the bitmap rows in `rows` (top-down, half-open). Anti-aliased
    /// text pixels vary in color and never outnumber a text field's flat background, so the mode is
    /// the background even when the rows are full of glyphs. Nil when the range is empty.
    static func dominantColor(in bitmap: RGBABitmap, rows: Range<Int>) -> RGBABitmap.Pixel? {
        let lower = max(0, rows.lowerBound)
        let upper = min(bitmap.height, rows.upperBound)
        guard lower < upper, bitmap.width > 0 else { return nil }
        var counts: [UInt32: Int] = [:]
        for row in lower..<upper {
            var offset = row * bitmap.width * 4
            for _ in 0..<bitmap.width {
                let key = UInt32(bitmap.bytes[offset]) << 16
                    | UInt32(bitmap.bytes[offset + 1]) << 8
                    | UInt32(bitmap.bytes[offset + 2])
                counts[key, default: 0] += 1
                offset += 4
            }
        }
        // Ties are broken by the darker key so the pick is deterministic across runs.
        guard let winner = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key else { return nil }
        return RGBABitmap.Pixel(
            red: Double((winner >> 16) & 0xFF) / 255,
            green: Double((winner >> 8) & 0xFF) / 255,
            blue: Double(winner & 0xFF) / 255
        )
    }
}
