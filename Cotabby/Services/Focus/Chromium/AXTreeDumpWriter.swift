import ApplicationServices
import Foundation
import Logging

/// File overview:
/// Renders the focused AX element plus its ancestors and children to plain text and overwrites
/// `ax-dump.txt` in the debug artifact directory (`CotabbyDebugArtifacts`, under
/// `~/Library/Logs/<app>/`). This is a developer diagnostic for triaging caret-placement and
/// host-AX-publish issues (primarily Chrome contenteditables), kept out of `FocusSnapshotResolver`
/// so that hot path stays focused on snapshot assembly rather than diagnostic disk I/O.
///
/// The dump only runs under `-cotabby-debug`, only for the configured bundle, and is debounced to
/// one write per focused-element identity change so rapid focus/value notifications inside one
/// field don't overwrite the file mid-inspection. Writes are best-effort and owner-only.
///
/// The walk runs before the resolver's own secure-field check, so it applies that policy itself:
/// a secure element, and everything under it, is printed without its value, selection, or caret.
@MainActor
enum AXTreeDumpWriter {
    /// Bundle identifier we automatically dump the AX tree for when `-cotabby-debug` is on.
    /// Chrome's contenteditable surfaces are the source of most caret-placement and host-AX-publish
    /// reports, so the dump exists primarily for triaging those — extend the gate (or replace the
    /// constant) once another bundle needs the same treatment.
    private static let dumpAXBundleIdentifier = "com.google.Chrome"
    /// Last focused-element identifier we wrote to disk. The dump only runs when this changes, so
    /// rapid focus events inside the same field don't repeatedly overwrite the file mid-inspection.
    private static var lastDumpedElementID: String?
    private static let dumpTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Writes the AX tree dump for `focusedElement`, but only under `-cotabby-debug`, only for the
    /// configured bundle (currently Chrome), and only when the focused element changed since the
    /// last dump (debounced by element identity). A no-op otherwise.
    static func dumpIfEnabled(
        focusedElement: AXUIElement,
        applicationName: String,
        bundleIdentifier: String,
        focusedElementIdentifier: String
    ) {
        guard CotabbyDebugOptions.isEnabled,
              bundleIdentifier == dumpAXBundleIdentifier,
              lastDumpedElementID != focusedElementIdentifier else {
            return
        }
        lastDumpedElementID = focusedElementIdentifier
        writeAXTreeDump(
            focusedElement: focusedElement,
            app: applicationName,
            bundle: bundleIdentifier
        )
    }

    /// Renders the focused element plus its ancestors and children to plain text and overwrites
    /// `ax-dump.txt` in the debug artifact directory. The file is overwritten so the user (or an AI
    /// debugger) always inspects the latest snapshot at a stable path.
    ///
    /// Writes are best-effort: a failed disk write is logged through `CotabbyLogger.focus` and
    /// does not propagate, since AX dumping is purely diagnostic.
    private static func writeAXTreeDump(focusedElement: AXUIElement, app: String, bundle: String) {
        let timestamp = Self.dumpTimestampFormatter.string(from: Date())
        var out = "========== AX TREE DUMP ==========\n"
        out += "Timestamp: \(timestamp)\n"
        out += "App: \(app) (\(bundle))\n\n"

        out += "-- Focused + ancestors --\n"
        var ancestors: [AXUIElement] = [focusedElement]
        var currentElement = focusedElement
        for _ in 0..<3 {
            guard let parent = AXHelper.parentElement(of: currentElement) else { break }
            ancestors.append(parent)
            currentElement = parent
        }
        // Printed outermost first, so a secure ancestor's flag carries down to the focused element,
        // and the focused element's (printed last) carries into its children.
        var insideSecureField = false
        for (offset, element) in ancestors.enumerated().reversed() {
            let indent = String(repeating: "  ", count: ancestors.count - 1 - offset)
            let node = describeNode(element, indent: indent, insideSecureField: insideSecureField)
            out += node.text
            insideSecureField = node.isSecure
        }

        out += "\n-- Children (depth 6) --\n"
        dumpChildrenRecursive(of: focusedElement, into: &out, indent: "", depth: 0, insideSecureField: insideSecureField)

        out += "========== END DUMP ==========\n"

        guard let directory = CotabbyDebugArtifacts.preparedDirectory() else {
            CotabbyLogger.focus.error("AX dump skipped: debug artifact directory unavailable")
            return
        }
        let targetURL = directory.appendingPathComponent(CotabbyDebugArtifacts.axDumpName, isDirectory: false)
        if CotabbyDebugArtifacts.writePrivateFile(Data(out.utf8), to: targetURL) {
            CotabbyLogger.focus.debug(
                "Wrote AX dump",
                metadata: [
                    "path": .string(targetURL.path),
                    "bundle": .string(bundle)
                ]
            )
        } else {
            CotabbyLogger.focus.error(
                "Failed to write AX dump",
                metadata: ["path": .string(targetURL.path)]
            )
        }
    }

    private static func dumpChildrenRecursive(
        of element: AXUIElement,
        into out: inout String,
        indent: String,
        depth: Int,
        insideSecureField: Bool
    ) {
        guard depth < 6 else { return }
        let children = AXHelper.childElements(of: element)
        for (offset, child) in children.prefix(20).enumerated() {
            let node = describeNode(child, indent: "\(indent)[\(offset)] ", insideSecureField: insideSecureField)
            out += node.text
            dumpChildrenRecursive(
                of: child, into: &out, indent: indent + "  ", depth: depth + 1, insideSecureField: node.isSecure
            )
        }
        if children.count > 20 {
            out += "\(indent)  ...+\(children.count - 20) more\n"
        }
    }

    /// One node's lines, and whether it counts as secure for the nodes under it: it is secure by
    /// `SecureFieldDetector`'s markers, or it sits inside an element that is.
    private static func describeNode(
        _ element: AXUIElement,
        indent: String,
        insideSecureField: Bool
    ) -> (text: String, isSecure: Bool) {
        let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) ?? "?"
        let subrole = AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element)
        let attributes = Set(AXHelper.attributeNames(on: element))
        let parameterizedAttributes = Set(AXHelper.parameterizedAttributeNames(on: element))
        let isSecure = insideSecureField || SecureFieldDetector.isSecure(
            role: role,
            subrole: subrole,
            roleDescription: AXHelper.stringValue(for: kAXRoleDescriptionAttribute as CFString, on: element),
            title: AXHelper.stringValue(for: kAXTitleAttribute as CFString, on: element),
            descriptionLabel: AXHelper.stringValue(for: kAXDescriptionAttribute as CFString, on: element)
        )

        var summary = "\(indent)\(role)"
        if let subrole { summary += " (\(subrole))" }
        summary += "\n"

        if let frame = AXHelper.rectValue(for: "AXFrame" as CFString, on: element) {
            let cocoa = AXHelper.cocoaRect(fromAccessibilityRect: frame)
            summary += "\(indent)  frame(AX): \(fmt(frame))  frame(cocoa): \(fmt(cocoa))\n"
        }

        // A secure element's value is never read, so no later edit to the preview can leak it.
        if attributes.contains(kAXValueAttribute as String),
           let text = isSecure ? "" : AXHelper.stringValue(for: kAXValueAttribute as CFString, on: element) {
            summary += "\(indent)  value: \(AXDumpValuePreview.line(for: text, isSecure: isSecure))\n"
        }

        // The selection and caret of a secure field give away how long its value is.
        if !isSecure, let range = AXHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element) {
            summary += "\(indent)  selection: loc=\(range.location) len=\(range.length)\n"

            if parameterizedAttributes.contains(kAXBoundsForRangeParameterizedAttribute as String) {
                let boundsRect = AXHelper.parameterizedRectValue(
                    for: kAXBoundsForRangeParameterizedAttribute as CFString,
                    range: NSRange(location: range.location, length: 0),
                    on: element
                )
                if let boundsRect, !boundsRect.isEmpty {
                    summary += "\(indent)  BoundsForRange(loc,0): \(fmt(boundsRect))\n"
                } else {
                    summary += "\(indent)  BoundsForRange(loc,0): FAILED\n"
                }
            }
        }

        if !isSecure, let markerRect = AXHelper.textMarkerCaretRect(on: element), !markerRect.isEmpty {
            summary += "\(indent)  TextMarkerCaret: \(fmt(markerRect))\n"
        }

        if let isEditable = AXHelper.boolValue(for: "AXEditable" as CFString, on: element) {
            summary += "\(indent)  editable: \(isEditable)\n"
        }

        let childCount = AXHelper.childElements(of: element).count
        if childCount > 0 { summary += "\(indent)  children: \(childCount)\n" }

        return (summary, isSecure)
    }

    private static func fmt(_ rect: CGRect) -> String {
        String(format: "(%.0f, %.0f, %.0f×%.0f)", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }
}
