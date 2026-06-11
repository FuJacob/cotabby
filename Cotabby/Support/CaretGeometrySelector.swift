import CoreGraphics
import Foundation

/// Pure caret-geometry trust policy used by `FocusSnapshotResolver`.
///
/// Two decisions live here, kept free of live Accessibility objects so they can be unit tested:
///   1. `shouldSearchDeep` — whether the focused input's own caret geometry is too weak to trust,
///      so the resolver should run the expensive deep AX-tree walk for a better source.
///   2. `select` — given the primary candidate's geometry and an optional deep-walk result, which
///      rect to actually ship, following a fixed precedence.
///
/// The regression these protect against is trusting a descendant rect over the focused input's own
/// usable rect (or vice versa). Chrome's AXTextArea answers BoundsForRange with a multi-line union
/// rect — labelled `.derived` but unusable for precise caret placement — while the leaf AXStaticText
/// holding the active line carries a real `.exact` rect that the deep walk can recover.
enum CaretGeometrySelector {
    /// The caret geometry chosen to ship, plus a human-readable source label for diagnostics.
    struct Selected: Equatable {
        let rect: CGRect
        let source: String
        let quality: CaretGeometryQuality
        let observedCharWidth: CGFloat?
        let observedContentEdges: ObservedContentEdges?
    }

    /// Whether the primary (focused-input) caret geometry is too weak to trust, so the resolver
    /// should run the deep AX-tree walk for a more precise source.
    ///
    /// `.exact` and `.derived` are trusted as-is; only `.estimated`, unknown quality, or a missing
    /// rect justify the ~200-node walk. The walk pins a CPU core when run on every keystroke, so we
    /// avoid it whenever the primary geometry is already good enough.
    static func shouldSearchDeep(
        primaryRect: CGRect?,
        primaryQuality: CaretGeometryQuality?
    ) -> Bool {
        guard primaryRect != nil else {
            return true
        }
        switch primaryQuality {
        case .exact, .derived:
            return false
        default:
            return true
        }
    }

    /// Chooses the caret geometry to ship from the primary candidate and the optional deep-tree
    /// result. Returns `nil` when neither source produced a rect, which the caller maps to an
    /// unsupported snapshot.
    ///
    /// Precedence:
    ///   1. primary `.exact`    (single API call, perfect — no walk needed)
    ///   2. primary `.derived`  (trusted; `shouldSearchDeep` skips the walk entirely for it)
    ///   3. deep (any)          (only reached when primary is `.estimated`/unknown)
    ///   4. primary (any, fallback)
    static func select(
        primaryRect: CGRect?,
        primaryQuality: CaretGeometryQuality?,
        primaryObservedCharWidth: CGFloat?,
        primaryObservedContentEdges: ObservedContentEdges? = nil,
        primarySourceDetail: String? = nil,
        deepResult: CaretGeometryResult?
    ) -> Selected? {
        if let primary = primaryRect, primaryQuality == .exact {
            return Selected(
                rect: primary,
                source: labeled("exact primary", detail: primarySourceDetail),
                quality: .exact,
                observedCharWidth: primaryObservedCharWidth,
                observedContentEdges: primaryObservedContentEdges
            )
        }
        if let primary = primaryRect, primaryQuality == .derived {
            return Selected(
                rect: primary,
                source: labeled("derived primary", detail: primarySourceDetail),
                quality: .derived,
                observedCharWidth: primaryObservedCharWidth,
                observedContentEdges: primaryObservedContentEdges
            )
        }
        if let deep = deepResult {
            return Selected(
                rect: deep.rect,
                source: labeled("\(deep.quality.label) deep", detail: deep.sourceDetail),
                quality: deep.quality,
                observedCharWidth: deep.observedCharWidth,
                observedContentEdges: deep.observedContentEdges
            )
        }
        if let primary = primaryRect {
            return Selected(
                rect: primary,
                source: labeled(
                    "\(primaryQuality?.label ?? "unknown") primary-fallback",
                    detail: primarySourceDetail
                ),
                quality: primaryQuality ?? .estimated,
                observedCharWidth: primaryObservedCharWidth,
                observedContentEdges: primaryObservedContentEdges
            )
        }
        return nil
    }

    /// Appends resolver-supplied detail (e.g. the caret-to-run mapping mode) so the debug badge
    /// and structured logs show not just which branch produced the rect but how it mapped.
    private static func labeled(_ base: String, detail: String?) -> String {
        guard let detail, !detail.isEmpty else {
            return base
        }
        return "\(base) (\(detail))"
    }
}
