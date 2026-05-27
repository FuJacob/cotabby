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

    private var runKey: FieldKey?
    private var textRunElements: [AXUIElement]?

    private var deepKey: FieldKey?
    private var deepSourceElement: AXUIElement?

    /// Releasing the cache's storage (CF element references, strings, ints) is thread-safe, so the
    /// deinit does not need main-actor isolation. Marking it `nonisolated` keeps the rest of the type
    /// main-actor isolated while preventing the compiler from emitting an isolated-deinit hop. With
    /// our macOS 14 deployment target that hop runs through the back-deployment shim
    /// `swift_task_deinitOnExecutorMainActorBackDeploy`, which over-releases and aborts the process
    /// ("pointer being freed was not allocated") when a `@MainActor` class with non-trivial stored
    /// properties is destroyed — it crashed `CaretGeometrySourceCacheTests` deterministically.
    nonisolated deinit {}

    /// Debug-only counters (read by `FocusTracker` when `-cotabby-debug` is set) so a dump can show
    /// whether the cache is actually hitting in the wild rather than us guessing. Not used for logic.
    private(set) var runHits = 0
    private(set) var runMisses = 0
    private(set) var deepHits = 0
    private(set) var deepMisses = 0

    var debugStats: String {
        "run \(runHits)/\(runHits + runMisses) deep \(deepHits)/\(deepHits + deepMisses)"
    }

    /// Returns the cached ordered text-run leaves for `key`, or nil when the focused field changed
    /// (key mismatch) or nothing has been cached yet.
    func textRunElements(for key: FieldKey) -> [AXUIElement]? {
        guard runKey == key else {
            runMisses += 1
            return nil
        }
        runHits += 1
        return textRunElements
    }

    /// Replaces the cached leaves for `key`. Storing under a new key implicitly drops the previous
    /// field's entry, so the cache never holds more than one field at a time.
    func store(textRunElements elements: [AXUIElement], for key: FieldKey) {
        runKey = key
        textRunElements = elements
    }

    /// Returns the cached deep geometry source leaf — the element whose zero-length selection range
    /// produced the caret rect last time — so the resolver can read it directly instead of BFS-ing
    /// the subtree again. Nil on field change or cold cache.
    func deepSource(for key: FieldKey) -> AXUIElement? {
        guard deepKey == key else {
            deepMisses += 1
            return nil
        }
        deepHits += 1
        return deepSourceElement
    }

    func store(deepSource element: AXUIElement, for key: FieldKey) {
        deepKey = key
        deepSourceElement = element
    }

    func invalidate() {
        runKey = nil
        textRunElements = nil
        deepKey = nil
        deepSourceElement = nil
    }
}
