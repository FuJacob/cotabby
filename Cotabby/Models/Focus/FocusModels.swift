import CoreGraphics
import Foundation

/// File overview:
/// Pure data models for focused-input state, AX capability support, and stale-result signatures.
/// These types let the rest of Cotabby reason about focus without depending on raw Accessibility values.

/// Immutable identity for one focused input observation.
///
/// `elementIdentifier` is still useful because it describes the AX node we resolved, but it is not
/// globally unique over time: macOS can recycle `CFHash` values after AX elements are destroyed.
/// Pairing it with `focusChangeSequence` gives async consumers a stable "same focus event" key.
nonisolated struct FocusedInputIdentity: Equatable, Sendable {
    let elementIdentifier: String
    let focusChangeSequence: UInt64
}

/// Describes how trustworthy the resolved caret rect is.
///
/// This distinction matters because not every downstream feature should treat all caret geometry
/// the same way. Exact and derived rects are safe to anchor UI to aggressively. Estimated rects
/// are useful for "there is a field here" signaling, but should be handled conservatively to avoid
/// visibly marching away from the real insertion point.
nonisolated enum CaretGeometryQuality: Equatable, Sendable {
    case exact
    case derived
    case estimated

    /// Produced only at presentation time by `TextLayoutCaretEstimator`, never by the AX
    /// resolvers: the caret was recomputed from a hidden text layout of the prefix anchored to
    /// the field frame, after the resolver could offer nothing better than `.estimated`. Kept as
    /// its own case (instead of reusing `.derived`, which means "measured from real AX child
    /// frames") so caret-placement debugging in the logs stays honest about the source. Trusted
    /// enough to render inline ghost text.
    case layoutEstimated

    var label: String {
        switch self {
        case .exact:
            return "exact"
        case .derived:
            return "derived"
        case .estimated:
            return "estimated"
        case .layoutEstimated:
            return "layout-estimated"
        }
    }
}
///
/// These are the concrete Accessibility capabilities Cotabby needs before it can safely assist a field.
/// The key lesson is that "editable role" is not enough; we care about operational capability.
enum FocusCapabilityRequirement: String, CaseIterable, Equatable {
    case textValue
    case selectionRange
    case caretBounds
    case editableTarget

    var summary: String {
        switch self {
        case .textValue:
            return "Text value"
        case .selectionRange:
            return "Selection range"
        case .caretBounds:
            return "Caret bounds"
        case .editableTarget:
            return "Editable target"
        }
    }

    var unsupportedReason: String {
        "Missing \(summary.lowercased())."
    }
}

/// Distinguishes "unsupported" from "blocked".
/// Unsupported means the host does not expose enough AX data.
/// Blocked means Cotabby intentionally refuses to operate, for example in secure fields.
enum FocusCapability: Equatable {
    case supported
    case blocked(String)
    case unsupported(String)

    /// Short labels are better for menu bar UI than long diagnostic sentences.
    var shortLabel: String {
        switch self {
        case .supported:
            return "Supported"
        case .blocked:
            return "Blocked"
        case .unsupported:
            return "Unsupported"
        }
    }

    var summary: String {
        switch self {
        case .supported:
            return "Supported"
        case let .blocked(reason), let .unsupported(reason):
            return reason
        }
    }
}

/// Visual style of the focused field's own text, resolved from Accessibility so ghost text can be
/// rendered to match it instead of always using the system font and a fixed gray.
///
/// Every field is optional: any attribute the host does not expose stays nil and the overlay falls
/// back to its default styling. Stored as plain value types (no `NSFont`/`NSColor`) so the snapshot
/// stays `Equatable`/`Sendable` and is cheap to carry across async boundaries.
nonisolated struct ResolvedFieldStyle: Equatable, Sendable {
    /// PostScript font name suitable for `NSFont(name:size:)`. Native AppKit hosts report it
    /// (`Menlo-Regular`, `Helvetica`, `.AppleSystemUIFont`); web engines usually omit it.
    let fontName: String?
    /// Family name (`AXFontFamily`), kept separately because a host can report the family without
    /// a PostScript face, and the family alone still selects the right typeface.
    let fontFamily: String?
    /// Host-reported point size. This is the ghost font's rendered size whenever it is plausible:
    /// matching the host's size exactly is what makes ghost glyphs line up with the host's text.
    /// Chromium reports only this field, so a size-only style is a real, useful style.
    let fontPointSize: CGFloat?
    /// Foreground text color as a 6-digit hex string (see `SuggestionTextColorCodec`).
    let colorHex: String?

    init(fontName: String?, fontFamily: String? = nil, fontPointSize: CGFloat?, colorHex: String?) {
        self.fontName = fontName
        self.fontFamily = fontFamily
        self.fontPointSize = fontPointSize
        self.colorHex = colorHex
    }

    /// True when the host exposed nothing usable at all. A size-only style is NOT empty: the point
    /// size is the single most important fact for matching the host's rendering.
    var isEmpty: Bool {
        fontName == nil && fontFamily == nil && fontPointSize == nil && colorHex == nil
    }
}

/// Facts about how the host actually renders the text next to the caret, measured from the host's
/// own Accessibility geometry rather than guessed from font tables. `GhostFontResolver` uses the
/// width sample to pick (or scale) a typeface when the host names no family, and the line pitch
/// lets a wrapped ghost place its second row exactly where the host would place the next line.
///
/// Every field is optional: a host that exposes no line or range bounds simply contributes nothing
/// and the ghost falls back to font-table metrics. Plain value type so it rides along in the
/// `Equatable`/`Sendable` snapshot.
nonisolated struct HostTextMetrics: Equatable, Sendable {
    /// Text immediately before the caret on the caret's line whose rendered width was measured.
    let sampleText: String?
    /// Rendered width of `sampleText` in points, from the host's own bounds-for-range answer.
    let sampleWidth: CGFloat?
    /// The host's rendered box for the caret's whole visual line, in global Cocoa coordinates.
    /// Its `minX` is the real content left edge (where a wrapped ghost row starts).
    let lineRect: CGRect?
    /// Vertical distance between consecutive visual lines, when the host exposes line geometry.
    let linePitch: CGFloat?

    init(sampleText: String? = nil, sampleWidth: CGFloat? = nil, lineRect: CGRect? = nil, linePitch: CGFloat? = nil) {
        self.sampleText = sampleText
        self.sampleWidth = sampleWidth
        self.lineRect = lineRect
        self.linePitch = linePitch
    }

    var isEmpty: Bool {
        sampleText == nil && lineRect == nil && linePitch == nil
    }
}

/// Real content edges measured from the host's own AX child text-run frames (Gmail/Outlook-class
/// editors). The field's `AXFrame` includes its padding, which AX never reports directly; the
/// leftmost/topmost rendered text runs reveal where content actually starts. Used by the caret
/// layout estimator instead of guessed insets, so its anchor matches the host's real padding.
/// These are live per-field measurements, not per-app knowledge.
nonisolated struct ObservedContentEdges: Equatable, Sendable {
    /// Global Cocoa-coordinate X of the leftmost text run's leading edge.
    let leftX: CGFloat
    /// Global Cocoa-coordinate top edge (maxY) of the topmost text run.
    let topY: CGFloat
    /// Vertical distance between consecutive single-line runs, when at least two were seen: the
    /// host's line pitch for editors whose line APIs give none (CodeMirror in Obsidian).
    var linePitch: CGFloat?
    /// Height of a single-line run's box (the rendered line box, which can be shorter than the
    /// pitch when the host adds leading between lines).
    var lineBoxHeight: CGFloat?
    /// Set when the caret sits inside one run whose frame is the union of several wrapped lines;
    /// the caret's line inside it is found by laying the paragraph out (see `WrappedRunAnchor`).
    var wrappedRun: WrappedRunAnchor?
}

/// A caret inside a static-text run that spans several wrapped visual lines as one frame.
/// CodeMirror (Obsidian) exposes each paragraph as one `AXStaticText` whose frame is the union of
/// its wrapped lines, with no per-character bounds; proportional placement inside that union is
/// meaningless, but laying the paragraph out in the union's width with the host's font recovers
/// the caret's visual line, and the union's top plus the sibling runs' pitch gives that line's
/// exact position. Measured live: the alternative (mapping the caret against neighbouring runs)
/// put the ghost two lines away and flapped between lines while typing.
nonisolated struct WrappedRunAnchor: Equatable, Sendable {
    /// The run's frame in global Cocoa coordinates.
    let frame: CGRect
    /// The caret's run up to the caret, taken from the live parent value (from where the run's
    /// text was anchored in it) rather than from the run's own text, which lags while typing.
    let paragraphTextBeforeCaret: String
    /// True for a run that is one visual line (a short paragraph): its frame is already the
    /// caret's line box, so the pixel read treats it as a single line and nothing lays its text
    /// out to find the line. False for a union run whose frame spans wrapped lines.
    var spansOneLine: Bool = false
}

/// This snapshot is the future handoff point into suggestion generation.
/// We store enough information to understand text context and caret placement without generating yet.
nonisolated struct FocusedInputSnapshot: Equatable {
    let applicationName: String
    let bundleIdentifier: String
    let processIdentifier: Int32
    let elementIdentifier: String
    let role: String
    let subrole: String?
    let caretRect: CGRect
    let inputFrameRect: CGRect?
    /// The focused element's own `AXFrame` in global Cocoa coordinates, read fresh on every poll and
    /// never widened. `inputFrameRect` is grown to a parent container or a 500pt minimum for card
    /// placement, so it cannot say where the host actually wraps; this can.
    let elementFrameRect: CGRect?
    /// The host's uncommitted (marked) text range in its own document coordinates, when it has one:
    /// macOS inline predictive text shown after the caret, or an IME composition before it. The
    /// host owns that span of the field until the user commits or dismisses it, so Cotabby must
    /// neither generate against it nor paint a ghost over it (see `HostMarkedTextPolicy`). Marked
    /// text after the caret is already excluded from `trailingText`.
    let hostMarkedTextRange: NSRange?
    let caretSource: String
    let caretQuality: CaretGeometryQuality
    /// Average character width in points observed from AX child frame measurements.
    /// Nil when the caret was resolved via BoundsForRange (no child walk needed).
    let observedCharWidth: CGFloat?
    /// Content edges measured from the same child text-run walk that produces
    /// `observedCharWidth`. Nil when no child runs were available.
    let observedContentEdges: ObservedContentEdges?
    let precedingText: String
    let trailingText: String
    let selection: NSRange
    let isSecure: Bool

    /// True when the resolved field is an xterm.js integrated-terminal surface (VS Code / Cursor /
    /// Windsurf terminal, or a browser-hosted web terminal). Set by `FocusSnapshotResolver` from the
    /// focused element's `AXDOMClassList`. Lets the availability gate suppress ghost text in the
    /// terminal without disabling the editor or Copilot chat, which share the same bundle id and so
    /// can't be separated by the app-level terminal blocklist. The initializer default keeps existing
    /// call sites compiling unchanged.
    let isIntegratedTerminal: Bool

    /// True when the resolved field's text is rendered by a web engine rather than a native text
    /// view (see `WebContentFieldDetector`). The caret layout repair keys its trust policy on
    /// this: web-engine caret bounds have known wrong-line pathologies the hidden-layout estimate
    /// may repair, while native AX bounds are ground truth the estimate must never override.
    /// The initializer default keeps existing call sites compiling unchanged.
    let isWebContentField: Bool

    /// Monotonic counter that increments every time polling observes a focused-input identity
    /// change.
    ///
    /// `elementIdentifier` is built from `CFHash`, which macOS can recycle when AX nodes are
    /// destroyed and recreated. That makes `elementIdentifier` unreliable for detecting field
    /// switches — two genuinely different text fields can produce the same identifier.
    ///
    /// This counter gives downstream consumers (especially `VisualContextCoordinator`) a
    /// guaranteed-unique signal that focus actually changed, independent of hash collisions.
    /// The initializer default of 0 keeps test and legacy call sites compiling without changes.
    let focusChangeSequence: UInt64

    /// The focused web page URL, when capture resolved one over Accessibility (browsers only, and only
    /// while per-site disable is enabled). Nil otherwise. Used solely by the per-site disable gate; the
    /// initializer default keeps every existing call site compiling unchanged.
    let focusedURLString: String?

    /// The host field's own text font/color, resolved once per focused element so ghost text can
    /// match it. Nil when the host exposes no usable style. The initializer default keeps existing
    /// call sites compiling unchanged.
    let resolvedFieldStyle: ResolvedFieldStyle?

    /// The focused window's title, read once per field session (cached by `SurfaceContextCache`)
    /// when surface context is enabled. The window title carries the highest-signal surface cue
    /// available over Accessibility: the email subject, document name, channel, or page title.
    /// Nil when disabled, unavailable, or the field is secure. The initializer default keeps
    /// existing call sites compiling unchanged.
    let windowTitle: String?

    /// The focused field's placeholder text (`AXPlaceholderValue`), read with the window title and
    /// under the same gating. Nil when absent. The initializer default keeps existing call sites
    /// compiling unchanged.
    let fieldPlaceholder: String?

    /// How the host renders text near the caret (measured widths, line box, line pitch), resolved
    /// once per field so the ghost can match the host's typeface and wrap geometry. Nil when the
    /// host exposes no measurable text geometry. The initializer default keeps existing call sites
    /// compiling unchanged.
    let hostTextMetrics: HostTextMetrics?

    /// Explicit initializer keeps `focusChangeSequence` immutable while preserving the old
    /// memberwise-call ergonomics for tests that do not care about focus identity.
    ///
    /// Swift omits `let` properties with inline defaults from the synthesized memberwise
    /// initializer. Writing the initializer ourselves gives production code a way to pass the real
    /// focus sequence, and keeps existing call sites working through the default value.
    init(
        applicationName: String,
        bundleIdentifier: String,
        processIdentifier: Int32,
        elementIdentifier: String,
        role: String,
        subrole: String?,
        caretRect: CGRect,
        inputFrameRect: CGRect?,
        caretSource: String,
        caretQuality: CaretGeometryQuality,
        observedCharWidth: CGFloat?,
        observedContentEdges: ObservedContentEdges? = nil,
        precedingText: String,
        trailingText: String,
        selection: NSRange,
        isSecure: Bool,
        isIntegratedTerminal: Bool = false,
        isWebContentField: Bool = false,
        focusChangeSequence: UInt64 = 0,
        focusedURLString: String? = nil,
        resolvedFieldStyle: ResolvedFieldStyle? = nil,
        windowTitle: String? = nil,
        fieldPlaceholder: String? = nil,
        hostTextMetrics: HostTextMetrics? = nil,
        elementFrameRect: CGRect? = nil,
        hostMarkedTextRange: NSRange? = nil
    ) {
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.elementIdentifier = elementIdentifier
        self.role = role
        self.subrole = subrole
        self.caretRect = caretRect
        self.inputFrameRect = inputFrameRect
        self.caretSource = caretSource
        self.caretQuality = caretQuality
        self.observedCharWidth = observedCharWidth
        self.observedContentEdges = observedContentEdges
        self.precedingText = precedingText
        self.trailingText = trailingText
        self.selection = selection
        self.isSecure = isSecure
        self.isIntegratedTerminal = isIntegratedTerminal
        self.isWebContentField = isWebContentField
        self.focusChangeSequence = focusChangeSequence
        self.focusedURLString = focusedURLString
        self.resolvedFieldStyle = resolvedFieldStyle
        self.windowTitle = windowTitle
        self.fieldPlaceholder = fieldPlaceholder
        self.hostTextMetrics = hostTextMetrics
        self.elementFrameRect = elementFrameRect
        self.hostMarkedTextRange = hostMarkedTextRange
    }

    var identity: FocusedInputIdentity {
        FocusedInputIdentity(
            elementIdentifier: elementIdentifier,
            focusChangeSequence: focusChangeSequence
        )
    }

    /// True while the host shows uncommitted text of its own (see `hostMarkedTextRange`).
    var hasHostMarkedText: Bool {
        (hostMarkedTextRange?.length ?? 0) > 0
    }

    /// The signature lets later pipeline stages detect whether a completion result is stale.
    /// This is the same idea you would use in a React app with a derived cache key.
    /// Content-only fingerprint for staleness detection. Deliberately excludes `elementIdentifier`
    /// because Chrome recycles AX node tokens between observations, making `CFHash`-based identity unstable.
    /// Text and selection state is sufficient to detect real content changes.
    var contentSignature: String {
        [
            String(selection.location),
            String(selection.length),
            precedingText,
            trailingText,
            isSecure ? "secure" : "plain"
        ].joined(separator: "::")
    }
}

/// Top-level focus state that the menu can render directly.
struct FocusSnapshot: Equatable {
    let applicationName: String
    let bundleIdentifier: String?
    let capability: FocusCapability
    let context: FocusedInputSnapshot?

    static let inactive = FocusSnapshot(
        applicationName: "No active application",
        bundleIdentifier: nil,
        capability: .unsupported("No focused text input"),
        context: nil
    )

    /// Returns the app identity that user-facing controls should target.
    ///
    /// Opening Cotabby's menu bar window can briefly make Cotabby the focused app. Treating Cotabby's own
    /// bundle identifier as ineligible protects the invariant that "Enable in X" continues to refer
    /// to the user's last real work app, not the helper UI they opened to change the setting.
    func externalApplicationIdentity(
        ignoredBundleIdentifier: String?
    ) -> FocusedApplicationIdentity? {
        guard let bundleIdentifier,
              bundleIdentifier != ignoredBundleIdentifier
        else {
            return nil
        }

        return FocusedApplicationIdentity(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier
        )
    }
}

/// Debug-only signal that one focus polling pass completed.
///
/// This intentionally stays separate from `FocusSnapshot`: a poll can be useful diagnostic
/// information even when the resolved focus snapshot does not change. The sequence number gives
/// Combine/SwiftUI consumers an always-unique value for repeated identical polls.
struct FocusPollingEvent: Equatable {
    let sequence: Int
    let focusChangeSequence: UInt64
    let didChangeFocusedInput: Bool
    let applicationName: String
    let capabilitySummary: String
    let occurredAt: Date

    var changeSummary: String {
        didChangeFocusedInput ? "changed" : "unchanged"
    }
}

/// Minimal identity for the last non-Cotabby application the user was working in.
///
/// The menu bar panel can steal focus when opened, so UI controls that target "the current app"
/// need a stable application identity that does not immediately collapse to Cotabby's own process.
struct FocusedApplicationIdentity: Equatable {
    let applicationName: String
    let bundleIdentifier: String
}
