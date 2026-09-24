import CoreGraphics
import Foundation

/// File overview:
/// The zoom factors a Chromium host paints at, so a size measured from its pixels can be snapped to
/// the exact size it paints: the CSS size it reports times one of those factors.
///
/// A Chromium or Electron host reports its font size in CSS pixels and nothing of its zoom (Claude's
/// composer reports 14 at any zoom), so the painted size has to be measured, and a pixel fit lands
/// within about half a percent of it: Obsidian's 16px system text matched at 15.99 in one field and
/// at 16.10 in the next (2026-09-11). Zoom is not continuous, though. Chrome zooms through fixed
/// percentages, and Electron through zoom levels half a level apart, each level a factor of 1.2:
/// Claude keeps `windowControlsZoomFactor` 1.0954451150103321 in its config.json (level 0.5), so its
/// composer paints 14px at 15.336pt, not the 15.4 a "110%" reading gives, a point short by the end of
/// a long ghost. A measured size within `tolerance` of the reported size times a factor on the
/// host's ladder is that product; anything else keeps its measurement.
///
/// Pure, so `OverlayController` asks it with the numbers it already has and the rule is tested on
/// its own; which ladder a host uses is decided by `HostZoomLadderResolver`.
nonisolated enum HostZoomLadder {
    enum Kind: String, Equatable, Sendable {
        /// Chrome, Arc, Brave, Edge: page zoom through Chrome's preset percentages.
        case chromeBrowser
        /// An Electron app: zoom levels, a factor of 1.2 per level, stepped by half a level.
        case electron
    }

    /// Chrome's page zoom presets (View > Zoom In, the default-zoom setting).
    static let chromeFactors: [CGFloat] = [
        0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5
    ]

    /// Electron's zoom levels from -8 to 9 in the half steps its View menu takes, as factors.
    static let electronFactors: [CGFloat] = stride(from: -8.0, through: 9.0, by: 0.5).map { CGFloat(pow(1.2, $0)) }

    /// How far a measurement may sit from a ladder size and still be it. Twice the spread measured
    /// between fields of one host, and a small fraction of the nearest steps' spacing (Chrome's
    /// closest presets are 9% apart, Electron's half levels 9.5%).
    static let tolerance: CGFloat = 0.01

    static func factors(for kind: Kind) -> [CGFloat] {
        switch kind {
        case .chromeBrowser: return chromeFactors
        case .electron: return electronFactors
        }
    }

    /// The reported size times the host's zoom factor nearest the measured size, when the
    /// measurement lies within `tolerance` of that product; nil otherwise.
    static func snappedSize(measured: CGFloat, reported: CGFloat, kind: Kind) -> CGFloat? {
        guard measured > 0, reported > 0, measured.isFinite, reported.isFinite else { return nil }
        let ratio = measured / reported
        guard let factor = factors(for: kind).min(by: { abs($0 - ratio) < abs($1 - ratio) }),
              abs(ratio / factor - 1) <= tolerance
        else {
            return nil
        }
        return reported * factor
    }
}
