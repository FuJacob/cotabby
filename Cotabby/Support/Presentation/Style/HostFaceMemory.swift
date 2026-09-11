import CoreGraphics
import Foundation

/// File overview:
/// Remembers, for each host text style, the face and size the last field there settled on, so the
/// next field in the same host starts in it instead of in the size the host reports.
///
/// Why this exists: a field settles its face from evidence it has to collect first, a caret width
/// sample of a dozen characters on one line or a pixel strip with enough ink. Until then a field
/// that names no face renders the reported size. Claude's composer reports 14 and paints Anthropic
/// Sans at 15.4, so every new message began with ghosts a tenth too small that grew once the
/// evidence arrived (measured 2026-09-10 in a replica of the composer: the first 26 to 77
/// presentations of every field at 14, then 15.2 to 15.9). A host sets the same text the same way
/// from one field to the next, so the last settled face is the best evidence a new field has, and
/// the field's own match replaces it as soon as it has one.
///
/// The same holds for the host's line pitch. A web engine's caret box is the glyph box, not the
/// line box, so a wrapped ghost row on a paragraph's first line (no line above to measure) stepped
/// down by the caret height: 19pt in Claude's composer, whose lines are 23pt apart, four points
/// high. The last pitch a field of the same style measured is the host's line-height.
///
/// Keyed by what makes two fields the same text style: the app (and, for a browser, the page
/// origin, since two sites share nothing), the size the host reports, the caret box height, and the
/// user's size multiplier. A value type in `Support/`; `OverlayController` owns the one instance
/// for the app's lifetime and keeps it across launches (`encoded()`, `init(restoring:)`): the first
/// field after a launch had nothing to start from, and Obsidian's showed the caret box's 17pt for
/// three seconds of typing before its pixel match named the 16pt system face (2026-09-11).
nonisolated struct HostFaceMemory: Sendable {
    struct Key: Hashable, Codable, Sendable {
        let host: String
        /// Reported size in quarter points, or -1 when the host reports none.
        let reportedSize: Int
        /// Caret box height in two-point steps, or -1 when the host reports its size.
        let caretHeight: Int
        /// The user's ghost size multiplier in percent.
        let sizeMultiplier: Int

        /// True for a browser page's style, whose host names the page's origin.
        var isPageScoped: Bool {
            host.contains("|")
        }

        /// Nil when there is no host to key on, or for a browser page whose origin is unknown.
        init?(
            bundleIdentifier: String?,
            urlString: String?,
            isBrowser: Bool,
            reportedSize: CGFloat?,
            caretHeight: CGFloat,
            sizeMultiplier: CGFloat
        ) {
            guard let bundleIdentifier, !bundleIdentifier.isEmpty, caretHeight > 0 else { return nil }
            if isBrowser {
                guard let urlString, let url = URL(string: urlString), let origin = url.host, !origin.isEmpty else {
                    return nil
                }
                host = bundleIdentifier + "|" + origin + (url.port.map { ":\($0)" } ?? "")
            } else {
                host = bundleIdentifier
            }
            self.reportedSize = reportedSize.map { Int(($0 * 4).rounded()) } ?? -1
            // With a reported size the caret box adds nothing, and Chromium's wanders by a point from
            // line to line (19 and 20pt in the composer replica, which split one style in two and
            // lost the line pitch it had measured); without one it is the only size signal, kept in
            // two-point steps.
            self.caretHeight = reportedSize == nil ? Int((caretHeight / 2).rounded()) : -1
            self.sizeMultiplier = Int((sizeMultiplier * 100).rounded())
        }
    }

    struct Face: Equatable, Codable, Sendable {
        let fontName: String
        let pointSize: CGFloat
    }

    /// Distinct styles kept; the first one recorded is the first forgotten.
    static let capacity = 48

    private struct Entry: Equatable {
        var face: Face?
        var pitch: CGFloat?
    }

    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []

    func face(for key: Key) -> Face? {
        entries[key]?.face
    }

    func pitch(for key: Key) -> CGFloat? {
        entries[key]?.pitch
    }

    /// Records `face` for `key`; true when that changed what is remembered (worth saving).
    @discardableResult
    mutating func record(_ face: Face, for key: Key) -> Bool {
        update(key) { $0.face = face }
    }

    /// Records the line pitch for `key`; true when that changed what is remembered.
    @discardableResult
    mutating func recordPitch(_ pitch: CGFloat, for key: Key) -> Bool {
        guard pitch > 0, pitch.isFinite else { return false }
        return update(key) { $0.pitch = pitch }
    }

    private mutating func update(_ key: Key, _ change: (inout Entry) -> Void) -> Bool {
        let before = entries[key]
        if before == nil {
            order.append(key)
        }
        var entry = before ?? Entry()
        change(&entry)
        entries[key] = entry
        while order.count > Self.capacity {
            entries[order.removeFirst()] = nil
        }
        return entry != before
    }

    /// One remembered style, as kept between launches.
    private struct Stored: Codable {
        let key: Key
        let face: Face?
        let pitch: CGFloat?
    }

    /// The remembered styles, oldest first, for keeping across launches. A browser page's style is
    /// kept only while the app runs: its key names the page's origin, and the sites a user typed on
    /// are not something to leave in the app's preferences.
    func encoded() -> Data? {
        let stored = order.filter { !$0.isPageScoped }.compactMap { key in
            entries[key].map { Stored(key: key, face: $0.face, pitch: $0.pitch) }
        }
        return try? JSONEncoder().encode(stored)
    }

    /// A resolution worth remembering: the host's own pixels named the face, or the field's adopted
    /// width sample sized the stand-in.
    static func isSettled(_ provenance: GhostFontResolver.Provenance, fieldAdoptedSample: Bool) -> Bool {
        switch provenance {
        case .pixelMatched:
            return true
        case .hostSizeScaledSystem:
            return fieldAdoptedSample
        default:
            return false
        }
    }

    /// A resolution a remembered face stands in for: nothing measured in this field yet (the reported
    /// or caret-derived size), or a family guessed from one width sample at the reported size.
    static func yieldsToMemory(_ provenance: GhostFontResolver.Provenance) -> Bool {
        switch provenance {
        case .hostSizeSystem, .caretDerived, .caretDerivedCalibrated, .hostSizeMatchedFamily:
            return true
        default:
            return false
        }
    }
}

extension HostFaceMemory {
    /// The memory `encoded()` produced, or an empty one for missing or unreadable data.
    init(restoring data: Data?) {
        self.init()
        guard let data, let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return }
        for item in stored.suffix(Self.capacity) {
            if let face = item.face {
                record(face, for: item.key)
            }
            if let pitch = item.pitch {
                recordPitch(pitch, for: item.key)
            }
        }
    }
}
