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
struct FocusedInputIdentity: Equatable, Sendable {
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

    var label: String {
        switch self {
        case .exact:
            return "exact"
        case .derived:
            return "derived"
        case .estimated:
            return "estimated"
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

    var focusedRoleSummary: String {
        "\(focusedRole) / \(focusedSubrole ?? "n/a")"
    }

    var resolvedRoleSummary: String {
        guard let resolvedRole else {
            return "Unavailable"
        }

        return "\(resolvedRole) / \(resolvedSubrole ?? "n/a")"
    }

    var missingCapabilitySummary: String {
        guard !missingCapabilities.isEmpty else {
            return "None"
        }

        return missingCapabilities.map(\.summary).joined(separator: ", ")
    }
}

/// This snapshot is the future handoff point into suggestion generation.
/// We store enough information to understand text context and caret placement without generating yet.
struct FocusedInputSnapshot: Equatable {
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
    let precedingText: String
    let trailingText: String
    let selection: NSRange
    let isSecure: Bool

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
        precedingText: String,
        trailingText: String,
        selection: NSRange,
        isSecure: Bool,
        focusChangeSequence: UInt64 = 0
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
        self.precedingText = precedingText
        self.trailingText = trailingText
        self.selection = selection
        self.isSecure = isSecure
        self.focusChangeSequence = focusChangeSequence
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

    var textPreview: String {
        let prefix = String(precedingText.suffix(32))
        let suffix = String(trailingText.prefix(32))
        return "\(prefix)|\(suffix)"
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
