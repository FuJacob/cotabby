import ApplicationServices
import Foundation
import Logging

/// File overview:
/// Renders the focused AX element plus its ancestors and children to plain text and overwrites
/// `~/Desktop/cotabby-ax-dump.txt`. This is a developer diagnostic for triaging caret-placement and
/// host-AX-publish issues (primarily Chrome contenteditables), kept out of `FocusSnapshotResolver`
/// so that hot path stays focused on snapshot assembly rather than diagnostic disk I/O.
///
/// The dump only runs on debug builds (`-cotabby-debug`), only for the configured bundle, and is
/// debounced to one write per focused-element identity change so rapid focus/value notifications
/// inside one field don't overwrite the file mid-inspection. Writes are best-effort.
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

    /// Writes the AX tree dump for `focusedElement`, but only on debug builds, only for the configured
    /// bundle (currently Chrome), and only when the focused element changed since the last dump
    /// (debounced by element identity). A no-op otherwise.
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
        writeAXTreeDumpToDesktop(
            focusedElement: focusedElement,
            app: applicationName,
            bundle: bundleIdentifier
        )
    }

    /// Renders the focused element plus its ancestors and children to plain text and overwrites
    /// `~/Desktop/cotabby-ax-dump.txt`. The file is overwritten so the user (or an AI debugger)
    /// always inspects the latest snapshot at a stable path.
    ///
    /// Writes are best-effort: a failed disk write is logged through `CotabbyLogger.focus` and
    /// does not propagate, since AX dumping is purely diagnostic.
    private static func writeAXTreeDumpToDesktop(focusedElement: AXUIElement, app: String, bundle: String) {
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
        for (offset, element) in ancestors.enumerated().reversed() {
            let indent = String(repeating: "  ", count: ancestors.count - 1 - offset)
            out += describeNode(element, indent: indent)
        }

        out += "\n-- Children (depth 6) --\n"
        dumpChildrenRecursive(of: focusedElement, into: &out, indent: "", depth: 0)

        out += "========== END DUMP ==========\n"

        guard let desktopURL = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first else {
            CotabbyLogger.focus.error("AX dump skipped: no Desktop directory available")
            return
        }
        let targetURL = desktopURL.appendingPathComponent("cotabby-ax-dump.txt", isDirectory: false)
        do {
            try out.write(to: targetURL, atomically: true, encoding: .utf8)
            CotabbyLogger.focus.debug(
                "Wrote AX dump",
                metadata: [
                    "path": .string(targetURL.path),
                    "bundle": .string(bundle)
                ]
            )
        } catch {
            CotabbyLogger.focus.error(
                "Failed to write AX dump: \(error.localizedDescription)",
                metadata: ["path": .string(targetURL.path)]
            )
        }
    }

    private static func dumpChildrenRecursive(
        of element: AXUIElement,
        into out: inout String,
        indent: String,
        depth: Int
    ) {
        guard depth < 6 else { return }
        let children = AXHelper.childElements(of: element)
        for (offset, child) in children.prefix(20).enumerated() {
            out += describeNode(child, indent: "\(indent)[\(offset)] ")
            dumpChildrenRecursive(of: child, into: &out, indent: indent + "  ", depth: depth + 1)
        }
        if children.count > 20 {
            out += "\(indent)  ...+\(children.count - 20) more\n"
        }
    }

    private static func describeNode(_ element: AXUIElement, indent: String) -> String {
        let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) ?? "?"
        let subrole = AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element)
        let attributes = Set(AXHelper.attributeNames(on: element))
        let parameterizedAttributes = Set(AXHelper.parameterizedAttributeNames(on: element))

        var summary = "\(indent)\(role)"
        if let subrole { summary += " (\(subrole))" }
        summary += "\n"

        if let frame = AXHelper.rectValue(for: "AXFrame" as CFString, on: element) {
            let cocoa = AXHelper.cocoaRect(fromAccessibilityRect: frame)
            summary += "\(indent)  frame(AX): \(fmt(frame))  frame(cocoa): \(fmt(cocoa))\n"
        }

        if attributes.contains(kAXValueAttribute as String),
            let text = AXHelper.stringValue(for: kAXValueAttribute as CFString, on: element) {
            let previewText = text.count > 80 ? String(text.prefix(80)) + "…" : text
            summary += "\(indent)  value: " +
                "\"\(previewText.replacingOccurrences(of: "\n", with: "\\n"))\" " +
                "(len=\(text.count))\n"
        }

        if let range = AXHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element) {
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

        if let markerRect = AXHelper.textMarkerCaretRect(on: element), !markerRect.isEmpty {
            summary += "\(indent)  TextMarkerCaret: \(fmt(markerRect))\n"
        }

        if let isEditable = AXHelper.boolValue(for: "AXEditable" as CFString, on: element) {
            summary += "\(indent)  editable: \(isEditable)\n"
        }

        let childCount = AXHelper.childElements(of: element).count
        if childCount > 0 { summary += "\(indent)  children: \(childCount)\n" }

        return summary
    }

    private static func fmt(_ rect: CGRect) -> String {
        String(format: "(%.0f, %.0f, %.0f×%.0f)", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }
}
