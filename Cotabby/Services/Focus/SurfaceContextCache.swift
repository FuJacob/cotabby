import Foundation

/// Surface metadata captured once per field session: the window title, the field's placeholder,
/// and (for browsers or the per-site gate) the page URL.
struct CapturedSurfaceContext: Equatable {
    let windowTitle: String?
    let fieldPlaceholder: String?
    let urlString: String?

    static let empty = CapturedSurfaceContext(windowTitle: nil, fieldPlaceholder: nil, urlString: nil)
}

/// Caches the captured surface metadata per focused field session so the synchronous AX reads
/// (window title, placeholder, URL walk) happen once per field, not on every focus poll.
///
/// Keyed on process + element + focusChangeSequence: the value is deliberately frozen for the
/// lifetime of one field session even if the window retitles mid-typing (a browser tab updating
/// its title on every keystroke would otherwise change the prompt bytes ahead of the prefix and
/// destroy the llama KV prefix reuse). A genuine focus change bumps the sequence and re-captures.
///
/// A reference type for the same reason as `FieldStyleCache`: it carries state across the
/// value-typed `FocusSnapshotResolver`'s non-mutating polls.
@MainActor
final class SurfaceContextCache {
    private var key: String?
    private var captured: CapturedSurfaceContext = .empty

    /// Stored-property @MainActor classes deallocated inside app-hosted tests double-free without
    /// an explicitly nonisolated deinit (the isolated-deinit runtime path over-releases). Same
    /// workaround as the other main-actor stores exercised by tests.
    nonisolated deinit {}

    /// Returns the cached capture when `key` matches the last resolution, otherwise resolves once
    /// and caches the result (including all-nil results, so a host exposing nothing is not
    /// re-probed every poll).
    func capture(forKey key: String, resolve: () -> CapturedSurfaceContext) -> CapturedSurfaceContext {
        if key == self.key {
            return captured
        }

        let resolved = resolve()
        self.key = key
        captured = resolved
        return resolved
    }
}
