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

/// Operator-facing debug information for how the resolver interpreted the AX tree.
struct FocusInspectionSnapshot: Equatable {
    let focusedElementIdentifier: String
    let focusedRole: String
    let focusedSubrole: String?
    let resolvedElementIdentifier: String?
    let resolvedRole: String?
    let resolvedSubrole: String?
    let missingCapabilities: [FocusCapabilityRequirement]
}

/// Visual style of the focused field's own text, resolved from Accessibility so ghost text can be
/// rendered to match it instead of always using the system font and a fixed gray.
///
/// Every field is optional: any attribute the host does not expose stays nil and the overlay falls
/// back to its default styling. Stored as plain value types (no `NSFont`/`NSColor`) so the snapshot
/// stays `Equatable`/`Sendable` and is cheap to carry across async boundaries.
nonisolated struct ResolvedFieldStyle: Equatable, Sendable {
    /// PostScript font name suitable for `NSFont(name:size:)`.
    let fontName: String?
    /// Host-reported point size, used only as the reference for scale-invariant metric sizing.
    let fontPointSize: CGFloat?
    /// Foreground text color as a 6-digit hex string (see `SuggestionTextColorCodec`).
    let colorHex: String?

    var isEmpty: Bool {
        fontName == nil && colorHex == nil
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
        fieldPlaceholder: String? = nil
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
    }

    var identity: FocusedInputIdentity {
        FocusedInputIdentity(
            elementIdentifier: elementIdentifier,
            focusChangeSequence: focusChangeSequence
        )
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
    let inspection: FocusInspectionSnapshot?

    static let inactive = FocusSnapshot(
        applicationName: "No active application",
        bundleIdentifier: nil,
        capability: .unsupported("No focused text input"),
        context: nil,
        inspection: nil
    )

    var capabilitySummary: String {
        capability.summary
    }

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
