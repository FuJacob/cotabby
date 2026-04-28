import CoreGraphics
import Foundation

/// File overview:
/// Pure data models for focused-input state, AX capability support, and stale-result signatures.
/// These types let the rest of Tabby reason about focus without depending on raw Accessibility values.

/// Describes how trustworthy the resolved caret rect is.
///
/// This distinction matters because not every downstream feature should treat all caret geometry
/// the same way. Exact and derived rects are safe to anchor UI to aggressively. Estimated rects
/// are useful for "there is a field here" signaling, but should be handled conservatively to avoid
/// visibly marching away from the real insertion point.
enum CaretGeometryQuality: Equatable, Sendable {
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
/// These are the concrete Accessibility capabilities Tabby needs before it can safely assist a field.
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
/// Blocked means Tabby intentionally refuses to operate, for example in secure fields.
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

    /// The signature lets later pipeline stages detect whether a completion result is stale.
    /// This is the same idea you would use in a React app with a derived cache key.
    /// Content-only fingerprint for staleness detection. Deliberately excludes `elementIdentifier`
    /// because Chrome recycles AX node tokens between polls, making `CFHash`-based identity unstable.
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
    /// Opening Tabby's menu bar window can briefly make Tabby the focused app. Treating Tabby's own
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

/// Minimal identity for the last non-Tabby application the user was working in.
///
/// The menu bar panel can steal focus when opened, so UI controls that target "the current app"
/// need a stable application identity that does not immediately collapse to Tabby's own process.
struct FocusedApplicationIdentity: Equatable {
    let applicationName: String
    let bundleIdentifier: String
}
