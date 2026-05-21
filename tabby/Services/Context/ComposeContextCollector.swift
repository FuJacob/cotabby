import ApplicationServices
import Foundation

/// Bounded Accessibility tree collection for Compose Mode.
///
/// This service is intentionally separate from `SuggestionCoordinator`: AX tree walking is a
/// side-effectful macOS boundary with app-specific failure modes. The coordinator should ask for a
/// bounded, normalized context string; it should not own traversal budgets or Core Foundation reads.
@MainActor
final class ComposeContextCollector {
    struct Limits: Equatable, Sendable {
        let maxAncestorDepth: Int
        let maxDFSDepth: Int
        let maxNodes: Int
        let maxRawContextCharacters: Int
        let normalizerLimits: ComposeContextNormalizer.Limits

        static let standard = Limits(
            maxAncestorDepth: 8,
            maxDFSDepth: 12,
            maxNodes: 500,
            maxRawContextCharacters: 30_000,
            normalizerLimits: .standard
        )
    }

    struct Result: Equatable, Sendable {
        let text: String
        let visitedNodeCount: Int
        let retainedTextCount: Int
        let droppedTextCount: Int
    }

    enum CollectionError: LocalizedError, Equatable {
        case noFocusedElement
        case staleFocus

        var errorDescription: String? {
            switch self {
            case .noFocusedElement:
                return "No focused Accessibility element was available for Compose context."
            case .staleFocus:
                return "Focused field changed before Compose context could be collected."
            }
        }
    }

    private struct TraversalRoot {
        let element: AXUIElement
        let matchedFocusedInput: Bool
    }

    private let limits: Limits

    private static let allowedRoles: Set<String> = [
        kAXStaticTextRole as String,
        kAXTextAreaRole as String,
        kAXTextFieldRole as String,
        kAXDocumentRole as String
    ]

    private static let blockedRoles: Set<String> = [
        kAXButtonRole as String,
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXScrollBarRole as String,
        kAXMenuItemRole as String,
        kAXImageRole as String
    ]

    init(limits: Limits = .standard) {
        self.limits = limits
    }

    func collect(for context: FocusedInputContext) async throws -> Result {
        try Task.checkCancellation()

        guard let focusedElement = AXHelper.focusedElement() else {
            throw CollectionError.noFocusedElement
        }

        guard AXHelper.processIdentifier(for: focusedElement) == context.processIdentifier else {
            throw CollectionError.staleFocus
        }

        let traversalRoot = try resolveTraversalRoot(startingAt: focusedElement, context: context)
        guard traversalRoot.matchedFocusedInput else {
            throw CollectionError.staleFocus
        }

        var stack: [(element: AXUIElement, depth: Int)] = [(traversalRoot.element, 0)]
        var seenElementIdentities = Set<String>()
        var rawTextBlocks: [String] = []
        var visitedNodeCount = 0
        var retainedTextCount = 0
        var droppedTextCount = 0
        var rawCharacterCount = 0

        while let next = stack.popLast(), visitedNodeCount < limits.maxNodes {
            try Task.checkCancellation()

            let identity = AXHelper.elementIdentity(for: next.element)
            guard seenElementIdentities.insert(identity).inserted else {
                continue
            }

            visitedNodeCount += 1

            if visitedNodeCount.isMultiple(of: 25) {
                await Task.yield()
            }

            let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: next.element)

            if let role, Self.blockedRoles.contains(role) {
                droppedTextCount += 1
                continue
            }

            if let role, Self.allowedRoles.contains(role) {
                for text in readableTextBlocks(from: next.element) {
                    guard rawCharacterCount < limits.maxRawContextCharacters else {
                        droppedTextCount += 1
                        continue
                    }

                    rawTextBlocks.append(text)
                    rawCharacterCount += text.count + 1
                    retainedTextCount += 1
                }
            }

            guard next.depth < limits.maxDFSDepth else {
                continue
            }

            let children = AXHelper.childElements(of: next.element)
            for child in children.reversed() {
                stack.append((child, next.depth + 1))
            }
        }

        let normalizedText = ComposeContextNormalizer.normalize(
            rawTextBlocks.joined(separator: "\n"),
            limits: limits.normalizerLimits
        )

        return Result(
            text: normalizedText,
            visitedNodeCount: visitedNodeCount,
            retainedTextCount: retainedTextCount,
            droppedTextCount: droppedTextCount
        )
    }

    private func resolveTraversalRoot(
        startingAt focusedElement: AXUIElement,
        context: FocusedInputContext
    ) throws -> TraversalRoot {
        var current: AXUIElement? = focusedElement
        var fallbackRoot = focusedElement
        var matchedFocusedInput = false

        for _ in 0...limits.maxAncestorDepth {
            guard let element = current else {
                break
            }

            fallbackRoot = element
            if elementMatchesContext(element, context: context) {
                matchedFocusedInput = true
            }

            let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element)
            if role == kAXWindowRole as String {
                return TraversalRoot(element: element, matchedFocusedInput: matchedFocusedInput)
            }

            current = AXHelper.parentElement(of: element)
        }

        return TraversalRoot(element: fallbackRoot, matchedFocusedInput: matchedFocusedInput)
    }

    private func elementMatchesContext(
        _ element: AXUIElement,
        context: FocusedInputContext
    ) -> Bool {
        guard AXHelper.elementIdentifier(for: element, bundleIdentifier: context.bundleIdentifier) == context.elementIdentifier else {
            return false
        }

        let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element)
        let subrole = AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element)
        return role == context.role && subrole == context.subrole
    }

    private func readableTextBlocks(from element: AXUIElement) -> [String] {
        var blocks: [String] = []
        var seenBlocks = Set<String>()

        for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            guard let text = AXHelper.stringValue(for: attribute as CFString, on: element) else {
                continue
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seenBlocks.insert(trimmed).inserted else {
                continue
            }

            blocks.append(trimmed)
        }

        return blocks
    }
}
