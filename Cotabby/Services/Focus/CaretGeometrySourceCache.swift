import ApplicationServices
import Foundation

/// File overview:
/// Remembers the AX leaf elements that produced caret geometry for the currently focused field so
/// the resolver can re-read them directly instead of re-discovering them with a fresh tree walk on
/// every keystroke.
///
/// Why this exists: in Chromium editors the caret rect comes from per-line `AXStaticText` leaves,
/// and finding them means a bounded-but-real BFS (`collectStaticTextRuns`) on each focus poll. The
/// leaf *elements* are stable across keystrokes within a field even though their text and frames
/// change, so caching the element references turns the per-keystroke crawl into a handful of
/// attribute reads. The cache is intentionally a reference type: the resolvers are value-type
/// structs, so their own state cannot survive across calls.
///
/// Correctness contract: the cache is keyed by `(container identity, focusChangeSequence)`. The
/// sequence is the authoritative field-switch signal (`elementIdentifier` alone is `CFHash`-based
/// and can collide across recycled nodes), so a key match guarantees "same field, same focus." Even
/// on a match, callers must re-validate the cached elements before trusting them — a stale element
/// read simply misses and forces a re-walk.
@MainActor
final class CaretGeometrySourceCache {
    struct FieldKey: Equatable {
        let containerIdentifier: String
        let focusChangeSequence: UInt64
    }

    private var key: FieldKey?
    private var textRunElements: [AXUIElement]?

    /// Returns the cached ordered text-run leaves for `key`, or nil when the focused field changed
    /// (key mismatch) or nothing has been cached yet.
    func textRunElements(for key: FieldKey) -> [AXUIElement]? {
        guard self.key == key else {
            return nil
        }
        return textRunElements
    }

    /// Replaces the cached leaves for `key`. Storing under a new key implicitly drops the previous
    /// field's entry, so the cache never holds more than one field at a time.
    func store(textRunElements elements: [AXUIElement], for key: FieldKey) {
        self.key = key
        self.textRunElements = elements
    }

    func invalidate() {
        key = nil
        textRunElements = nil
    }
}
