import AppKit
import ApplicationServices
import Foundation
import Logging

/// File overview:
/// Resolves the most usable editable candidate around the current AX focus and materializes a
/// stable `FocusSnapshot`. This keeps AX candidate search and snapshot assembly separate from the
/// polling shell in `FocusTracker`.
@MainActor
struct FocusSnapshotResolver {
    private let geometryResolver: AXTextGeometryResolver

    // MARK: - Debug AX tree dump (temporary — remove after caret placement is fixed)
    /// When true, the resolver writes the AX tree (on focus change) and the caret-resolution
    /// summary (every snapshot) to `dumpFilePath`. The file is truncated on first write per
    /// process, so each app launch starts with an empty log and the file never accumulates
    /// across rebuilds.
    private static let dumpAXTree = false
    private static var lastDumpedElementID: String?
    private static let dumpFilePath = "\(NSHomeDirectory())/Desktop/cotabby-ax-dump.log"
    private static var hasTruncatedDumpFile = false

    init(geometryResolver: AXTextGeometryResolver? = nil) {
        self.geometryResolver = geometryResolver ?? AXTextGeometryResolver()
    }

    /// Resolves the best editable candidate around the focused AX node and materializes a focus snapshot.
    ///
    /// `focusChangeSequence` is a monotonic counter owned by `FocusTracker`. The resolver threads
    /// it into the resulting `FocusedInputSnapshot` so downstream consumers can detect field
    /// switches even when `CFHash`-based `elementIdentifier` collides across recycled AX nodes.
    func resolveSnapshot(
        focusedElement: AXUIElement,
        application: NSRunningApplication,
        focusChangeSequence: UInt64 = 0
    ) -> FocusSnapshot {
        let applicationName = application.localizedName ?? "Unknown"
        let bundleIdentifier = application.bundleIdentifier ?? "unknown.bundle"
        let focusedRole =
            AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: focusedElement) ?? "Unknown"
        let focusedSubrole = AXHelper.stringValue(
            for: kAXSubroleAttribute as CFString, on: focusedElement)
        let focusedElementIdentifier = AXHelper.elementIdentifier(
            for: focusedElement, bundleIdentifier: bundleIdentifier)

        // Dump once per element change so it doesn't spam on repeated focus/value notifications.
        if Self.dumpAXTree, Self.lastDumpedElementID != focusedElementIdentifier {
            Self.lastDumpedElementID = focusedElementIdentifier
            printAXTreeDump(
                focusedElement: focusedElement, app: applicationName, bundle: bundleIdentifier)
        }

        let candidates = candidateElements(around: focusedElement).map {
            candidateSnapshot(for: $0, bundleIdentifier: bundleIdentifier)
        }
        let resolution = FocusCapabilityResolver.resolve(
            candidates: candidates.map(\.resolverCandidate))
        let selectedCandidate = resolution.bestDiagnosticCandidate.flatMap { candidate in
            candidates.first(where: { $0.elementIdentifier == candidate.elementIdentifier })
        }
        let inspection = FocusInspectionSnapshot(
            focusedElementIdentifier: focusedElementIdentifier,
            focusedRole: focusedRole,
            focusedSubrole: focusedSubrole,
            resolvedElementIdentifier: selectedCandidate?.elementIdentifier,
            resolvedRole: selectedCandidate?.role,
            resolvedSubrole: selectedCandidate?.subrole,
            missingCapabilities: resolution.resolvedCandidate == nil
                ? resolution.missingCapabilities : []
        )

        guard let resolvedCandidate = selectedCandidate,
            resolution.resolvedCandidate != nil
        else {
            CotabbyLogger.focus.trace("Focus unsupported in \(applicationName): \(resolution.unsupportedReason)")
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported(resolution.unsupportedReason),
                context: nil,
                inspection: inspection
            )
        }

        guard let selection = resolvedCandidate.selection else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported("Selection range is unavailable."),
                context: nil,
                inspection: inspection
            )
        }

        guard selection.location >= 0, selection.length >= 0 else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported("Selection range is invalid."),
                context: nil,
                inspection: inspection
            )
        }

        let value = resolvedCandidate.textValue ?? ""
        // `NSRange` coming from AX is expressed in UTF-16 code units, which is why the code below
        // uses `NSString` instead of slicing a native Swift `String` directly.
        guard selection.location <= value.utf16.count else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported("Selection range exceeds the current field value."),
                context: nil,
                inspection: inspection
            )
        }

        // The input target and the geometry source don't need to be the same element.
        // Native AppKit apps give exact caret rects on the input target itself. Chrome's
        // AXTextArea, by contrast, answers BoundsForRange(loc-1, 1) with a multi-line union
        // rect — labeled `.derived` here but actually unusable. The leaf AXStaticText holding
        // the active line carries its own zero-length selection range and
        // AXSelectedTextMarkerRange, so the deep BFS in `resolveDeepGeometrySource` can
        // synthesize a real `.exact` rect via Branch 1.5 (TextMarker) on that leaf.
        //
        // Precedence:
        //   1. primary `.exact`   (single API call, perfect — no walk needed)
        //   2. deep `.exact`      (beats primary `.derived` so we escape Chrome's union-rect trap)
        //   3. primary `.derived`
        //   4. deep `.derived`
        //   5. primary `.estimated` / unknown fallback
        // The walk is skipped entirely when primary is already `.exact` to avoid wasted IPC.
        let deepResult: CaretGeometryResult? = (resolvedCandidate.caretQuality == .exact)
            ? nil
            : resolveDeepGeometrySource(
                focusedElement: focusedElement,
                resolvedElement: resolvedCandidate.element,
                cocoaAnchorFrame: resolvedCandidate.inputFrameRect
            )

        let caretRect: CGRect
        let caretSource: String
        let caretQuality: CaretGeometryQuality
        let observedCharWidth: CGFloat?
        if let primary = resolvedCandidate.caretRect, resolvedCandidate.caretQuality == .exact {
            caretRect = primary
            caretSource = "exact primary"
            caretQuality = .exact
            observedCharWidth = resolvedCandidate.observedCharWidth
        } else if let deep = deepResult, deep.quality == .exact {
            caretRect = deep.rect
            caretSource = "exact deep"
            caretQuality = .exact
            observedCharWidth = deep.observedCharWidth
        } else if let primary = resolvedCandidate.caretRect,
                  resolvedCandidate.caretQuality == .derived {
            caretRect = primary
            caretSource = "derived primary"
            caretQuality = .derived
            observedCharWidth = resolvedCandidate.observedCharWidth
        } else if let deep = deepResult {
            caretRect = deep.rect
            caretSource = "\(deep.quality.label) deep"
            caretQuality = deep.quality
            observedCharWidth = deep.observedCharWidth
        } else if let primary = resolvedCandidate.caretRect {
            caretRect = primary
            caretSource = "\(resolvedCandidate.caretQuality?.label ?? "unknown") primary-fallback"
            caretQuality = resolvedCandidate.caretQuality ?? .estimated
            observedCharWidth = resolvedCandidate.observedCharWidth
        } else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported("Caret bounds are unavailable."),
                context: nil,
                inspection: inspection
            )
        }

        if Self.dumpAXTree {
            var summary = "\n---------- CARET RESOLUTION [\(Self.dumpTimestamp())] ----------\n"
            summary += "App: \(applicationName) (\(bundleIdentifier))\n"
            summary += "Selection: loc=\(selection.location) len=\(selection.length)\n"
            summary += "Resolved candidate: role=\(resolvedCandidate.role)"
            if let subrole = resolvedCandidate.subrole {
                summary += " subrole=\(subrole)"
            }
            summary += "\n  id=\(resolvedCandidate.elementIdentifier)\n"
            summary += "  primary caretRect: \(resolvedCandidate.caretRect.map { fmt($0) } ?? "nil")\n"
            summary += "  primary caretQuality: \(resolvedCandidate.caretQuality?.label ?? "nil")\n"
            summary += "  anchor (inputFrameRect): \(resolvedCandidate.inputFrameRect.map { fmt($0) } ?? "nil")\n"
            summary += "=> Final caretRect: \(fmt(caretRect))\n"
            summary += "=> Final caretQuality: \(caretQuality.label)\n"
            summary += "=> Final caretSource: \(caretSource)\n"
            summary += "----------------------------------------------------------------\n"
            Self.appendToDumpFile(summary)
        }

        let nsValue = value as NSString
        let safeSelectionLocation = min(selection.location, nsValue.length)
        let trailingStart = min(selection.location + selection.length, nsValue.length)
        let context = FocusedInputSnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: Int32(application.processIdentifier),
            elementIdentifier: resolvedCandidate.elementIdentifier,
            role: resolvedCandidate.role,
            subrole: resolvedCandidate.subrole,
            caretRect: caretRect,
            inputFrameRect: resolvedCandidate.inputFrameRect,
            caretSource: caretSource,
            caretQuality: caretQuality,
            observedCharWidth: observedCharWidth,
            precedingText: nsValue.substring(to: safeSelectionLocation),
            trailingText: nsValue.substring(from: trailingStart),
            selection: selection,
            isSecure: resolvedCandidate.isSecure,
            focusChangeSequence: focusChangeSequence
        )

        if resolvedCandidate.isSecure {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .blocked("Secure text input is active."),
                context: context,
                inspection: inspection
            )
        }

        if selection.length > 0 {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .blocked("Text is currently selected."),
                context: context,
                inspection: inspection
            )
        }

        return FocusSnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            capability: .supported,
            context: context,
            inspection: inspection
        )
    }

    private func candidateElements(around focusedElement: AXUIElement) -> [AXUIElement] {
        var ordered: [AXUIElement] = []
        var seen = Set<String>()

        func append(_ element: AXUIElement?) {
            guard let element else {
                return
            }

            let identity = AXHelper.elementIdentity(for: element)
            guard seen.insert(identity).inserted else {
                return
            }

            ordered.append(element)
        }

        append(focusedElement)

        var ancestors: [AXUIElement] = []
        var currentElement = focusedElement
        for _ in 0..<2 {
            guard let parent = AXHelper.parentElement(of: currentElement) else {
                break
            }

            ancestors.append(parent)
            append(parent)
            currentElement = parent
        }

        // The heuristic search order is:
        // 1. focused node
        // 2. a couple of ancestors
        // 3. children of those nodes
        //
        // This is a pragmatic compromise for apps that focus a wrapper element instead of the real
        // editable text node. We do not try to walk the entire AX tree.
        for node in [focusedElement] + ancestors {
            for child in AXHelper.childElements(of: node) {
                append(child)
            }
        }

        return ordered
    }

    /// Runs deep geometry search from the resolved editable candidate first, then falls back to
    /// the raw focused node when those are different branches of the same local AX neighborhood.
    private func resolveDeepGeometrySource(
        focusedElement: AXUIElement,
        resolvedElement: AXUIElement,
        cocoaAnchorFrame: CGRect?
    ) -> CaretGeometryResult? {
        if let result = findDeepGeometrySource(
            from: resolvedElement,
            cocoaAnchorFrame: cocoaAnchorFrame
        ) {
            return result
        }

        guard
            AXHelper.elementIdentity(for: focusedElement)
                != AXHelper.elementIdentity(for: resolvedElement)
        else {
            return nil
        }

        return findDeepGeometrySource(
            from: focusedElement,
            cocoaAnchorFrame: cocoaAnchorFrame
        )
    }

    /// Searches deeper descendants of the focused element for a node with precise caret geometry.
    ///
    /// Chrome's AX tree nests live selection data on deep `AXStaticText` leaf nodes that have
    /// tight per-text-run frames — far more precise than the parent text entry area's AXFrame.
    /// We only read position from these nodes; the input target (where we type) stays unchanged.
    private func findDeepGeometrySource(
        from root: AXUIElement,
        cocoaAnchorFrame: CGRect?
    ) -> CaretGeometryResult? {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        let maxDepth = 10
        let maxNodes = 200
        var visited = 0
        var seen = Set<String>()
        var bestResult: (result: CaretGeometryResult, depth: Int)?

        while !queue.isEmpty, visited < maxNodes {
            let (element, depth) = queue.removeFirst()

            let identity = AXHelper.elementIdentity(for: element)
            guard seen.insert(identity).inserted else { continue }
            visited += 1

            // Look for any node with an active caret (zero-length selection).
            // Don't filter by role — Chrome uses AXStaticText for editable text runs.
            if let range = AXHelper.rangeValue(
                for: kAXSelectedTextRangeAttribute as CFString, on: element
            ), range.length == 0 {
                let attrs = Set(AXHelper.attributeNames(on: element))
                let textValue =
                    attrs.contains(kAXValueAttribute as String)
                    ? AXHelper.stringValue(for: kAXValueAttribute as CFString, on: element)
                    : nil
                let result = geometryResolver.resolveCaretRect(
                    for: element,
                    selection: range,
                    supportsFrame: attrs.contains("AXFrame"),
                    cocoaAnchorFrame: cocoaAnchorFrame,
                    textValue: textValue
                )

                if let result, result.quality == .exact || result.quality == .derived {
                    if shouldPreferDeepResult(
                        result,
                        at: depth,
                        over: bestResult
                    ) {
                        bestResult = (result, depth)
                    }
                }
            }

            guard depth < maxDepth else { continue }
            for child in AXHelper.childElements(of: element) {
                queue.append((child, depth + 1))
            }
        }

        return bestResult?.result
    }

    /// Prefers deeper descendants because browser AX wrappers can expose superficially "valid"
    /// geometry on shallow nodes while the real caret anchor lives lower in the text-run leaves.
    private func shouldPreferDeepResult(
        _ candidate: CaretGeometryResult,
        at depth: Int,
        over best: (result: CaretGeometryResult, depth: Int)?
    ) -> Bool {
        guard let best else {
            return true
        }

        if depth != best.depth {
            return depth > best.depth
        }

        return deepResultQualityScore(candidate.quality)
            > deepResultQualityScore(best.result.quality)
    }

    private func deepResultQualityScore(_ quality: CaretGeometryQuality) -> Int {
        switch quality {
        case .exact:
            return 2
        case .derived:
            return 1
        case .estimated:
            return 0
        }
    }

    /// Extracts the AX properties Cotabby needs from one candidate element near the current focus.
    private func candidateSnapshot(for element: AXUIElement, bundleIdentifier: String)
        -> AXFocusCandidate {
        let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) ?? "Unknown"
        let subrole = AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element)
        let supportedAttributes = Set(AXHelper.attributeNames(on: element))
        let explicitEditableFlag =
            supportedAttributes.contains("AXEditable")
            ? AXHelper.boolValue(for: "AXEditable" as CFString, on: element)
            : nil
        let textValue =
            supportedAttributes.contains(kAXValueAttribute as String)
            ? AXHelper.stringValue(for: kAXValueAttribute as CFString, on: element)
            : nil
        let selection =
            supportedAttributes.contains(kAXSelectedTextRangeAttribute as String)
            ? AXHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element)
            : nil
        var inputFrameRect =
            supportedAttributes.contains("AXFrame")
            ? geometryResolver.resolveInputFrameRect(for: element)
            : nil

        if let currentFrame = inputFrameRect {
            var finalWidth = currentFrame.width
            var finalX = currentFrame.minX

            // Optimization: grab the parent container's width if the active element is narrow
            // so we capture the whole input bar context (e.g. Discord/Slack dynamically sized nodes).
            if let parent = AXHelper.parentElement(of: element),
               let parentFrame = AXHelper.rectValue(for: "AXFrame" as CFString, on: parent) {
                let parentCocoa = AXHelper.cocoaRect(fromAccessibilityRect: parentFrame)
                if parentCocoa.width > finalWidth {
                    finalWidth = parentCocoa.width
                    finalX = parentCocoa.minX
                }
            }

            // Enforce a minimum width to ensure we get a decent horizontal slice.
            if finalWidth < 500 {
                finalWidth = max(finalWidth, 500)
            }

            inputFrameRect = CGRect(
                x: finalX,
                y: currentFrame.minY,
                width: finalWidth,
                height: currentFrame.height
            )
        }
        let caretResult = selection.flatMap {
            geometryResolver.resolveCaretRect(
                for: element,
                selection: $0,
                supportsFrame: supportedAttributes.contains("AXFrame"),
                cocoaAnchorFrame: inputFrameRect,
                textValue: textValue
            )
        }
        let caretRect = caretResult?.rect
        let caretQuality = caretResult?.quality
        let isSecure = isSecureElement(element: element, role: role, subrole: subrole)
        let elementIdentifier = AXHelper.elementIdentifier(
            for: element, bundleIdentifier: bundleIdentifier)
        let resolverCandidate = FocusCapabilityCandidate(
            elementIdentifier: elementIdentifier,
            role: role,
            subrole: subrole,
            editableHintScore: AXHelper.editabilityHintScore(
                role: role, explicitEditableFlag: explicitEditableFlag),
            hasStrongEditabilitySignal: AXHelper.hasStrongEditabilitySignal(
                role: role, explicitEditableFlag: explicitEditableFlag),
            isKnownReadOnlyRole: AXHelper.isKnownReadOnlyRole(role),
            hasTextValue: textValue != nil,
            hasSelectionRange: selection != nil,
            hasCaretBounds: caretRect != nil,
            isSecure: isSecure
        )

        return AXFocusCandidate(
            element: element,
            elementIdentifier: elementIdentifier,
            role: role,
            subrole: subrole,
            textValue: textValue,
            selection: selection,
            caretRect: caretRect,
            caretQuality: caretQuality,
            observedCharWidth: caretResult?.observedCharWidth,
            inputFrameRect: inputFrameRect,
            isSecure: isSecure,
            resolverCandidate: resolverCandidate
        )
    }

    /// Detects secure inputs so Cotabby can intentionally refuse to operate in sensitive fields.
    private func isSecureElement(element: AXUIElement, role: String, subrole: String?) -> Bool {
        let secureMarkers = [
            role.lowercased(),
            subrole?.lowercased() ?? "",
            AXHelper.stringValue(for: kAXDescriptionAttribute as CFString, on: element)?
                .lowercased() ?? "",
            AXHelper.stringValue(for: kAXTitleAttribute as CFString, on: element)?.lowercased()
                ?? ""
        ]

        return secureMarkers.contains { marker in
            marker.contains("secure") || marker.contains("password")
        }
    }

    // MARK: - Debug AX tree dump

    private func printAXTreeDump(focusedElement: AXUIElement, app: String, bundle: String) {
        var out = "\n========== AX TREE DUMP [\(Self.dumpTimestamp())] ==========\n"
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
        CotabbyLogger.focus.debug("\(out)")
        Self.appendToDumpFile(out)
    }

    /// Best-effort file sink for the AX dump. Truncates the log on the first write of the
    /// current process so each app launch starts clean (which is what the operator means by
    /// "always cleaned up after rebuilding"). All errors are swallowed — this is debug-only.
    private static func appendToDumpFile(_ text: String) {
        let url = URL(fileURLWithPath: dumpFilePath)

        if !hasTruncatedDumpFile {
            hasTruncatedDumpFile = true
            try? Data().write(to: url)
        }

        guard let handle = FileHandle(forWritingAtPath: dumpFilePath) else {
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            if let data = text.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } catch {
            // Ignored — debug-only sink, never block resolver flow on disk failure.
        }
    }

    private static func dumpTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    private func dumpChildrenRecursive(
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

    private func describeNode(_ element: AXUIElement, indent: String) -> String {
        let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) ?? "?"
        let subrole = AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element)
        let attributes = Set(AXHelper.attributeNames(on: element))

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

            // Try BoundsForRange unconditionally so the dump reflects what the production resolver
            // actually sees on Electron/WebKit elements that don't advertise the attribute.
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

    private func fmt(_ rect: CGRect) -> String {
        String(format: "(%.0f, %.0f, %.0f×%.0f)", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }
}

/// AX data read from one candidate element near the current focus.
/// This keeps candidate search state local to the resolver instead of leaking it into the tracker.
private struct AXFocusCandidate {
    let element: AXUIElement
    let elementIdentifier: String
    let role: String
    let subrole: String?
    let textValue: String?
    let selection: NSRange?
    let caretRect: CGRect?
    let caretQuality: CaretGeometryQuality?
    let observedCharWidth: CGFloat?
    let inputFrameRect: CGRect?
    let isSecure: Bool
    let resolverCandidate: FocusCapabilityCandidate
}
