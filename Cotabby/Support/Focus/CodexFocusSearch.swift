import Foundation

/// The resumable search for the focused text field inside the Codex desktop app's active window.
///
/// Codex's native shell can hide its focused web composer from `AXFocusedUIElement`, so the field
/// has to be found by walking the window's Accessibility tree for a node that is both an editable
/// text role and marked focused. That walk is far too long for one poll (every node costs
/// synchronous cross-process round trips), so it advances in short time slices across polls and
/// its position is the state kept here.
///
/// Generic over the node type and fed the tree through `Host`, so the transitions are unit-tested
/// against a scripted tree; `FocusTracker` supplies the real Accessibility reads.
struct CodexFocusSearch<Node> {
    /// A node waiting to be visited, with its depth below the window.
    struct Pending {
        let node: Node
        let depth: Int
    }

    enum State {
        /// Codex is not the frontmost capturable app; nothing is remembered.
        case inactive
        /// Walking `window` depth-first. `stack` is never empty: an exhausted walk cools down.
        case searching(window: Node, stack: [Pending], visits: Int)
        /// `field` was found focused in `window`. It is reused only while it stays focused.
        case found(window: Node, field: Node)
        /// The walk ended without a focused field; the next one may not start before `retryAt`.
        case coolingDown(window: Node, retryAt: Date)

        fileprivate var window: Node? {
            switch self {
            case .inactive:
                return nil
            case .searching(let window, _, _), .found(let window, _), .coolingDown(let window, _):
                return window
            }
        }
    }

    /// The reads the search needs from the tree it walks.
    struct Host {
        /// Whether two handles name the same node.
        let isSameNode: (Node, Node) -> Bool
        /// Whether a previously found field still holds focus.
        let isFocused: (Node) -> Bool
        /// Whether a node is an editable text role that currently holds focus.
        let isFocusedEditableField: (Node) -> Bool
        let children: (Node) -> [Node]
    }

    enum Resolution {
        /// The field found by an earlier poll, still focused.
        case reused(Node)
        /// The field this poll's slice of the walk reached.
        case found(Node)
    }

    /// Nodes one walk may visit before giving up. A window with no focused field would otherwise be
    /// walked end to end, again and again.
    static var maximumVisits: Int { 2000 }
    /// Depth below the window past which children are not followed.
    static var maximumDepth: Int { 40 }
    /// Wall-clock budget of one poll's share of the walk, short enough not to block typing.
    static var sliceDuration: TimeInterval { 0.015 }
    /// Pause after a walk that found nothing, so an unfocused window costs one walk a second.
    static var retryDelay: TimeInterval { 1 }

    private(set) var state: State = .inactive

    /// Forgets everything: Codex is no longer frontmost, capture is suppressed for it, or focus
    /// belongs to another process.
    mutating func deactivate() {
        state = .inactive
    }

    /// Advances the search by one poll and returns the focused field when it is known.
    ///
    /// A new `window` restarts the walk from it. A found field is reused while it stays focused and
    /// searched for again from the window the moment it does not. `now` is read repeatedly: once
    /// per visited node to hold the slice to `sliceDuration`.
    mutating func focusedField(
        in window: Node,
        host: Host,
        now: () -> Date = { Date() }
    ) -> Resolution? {
        if let current = state.window, host.isSameNode(current, window) {
            switch state {
            case .found(_, let field):
                if host.isFocused(field) {
                    return .reused(field)
                }
                restart(in: window)
            case .coolingDown(_, let retryAt):
                guard now() >= retryAt else {
                    return nil
                }
                restart(in: window)
            case .searching, .inactive:
                break
            }
        } else {
            restart(in: window)
        }
        return advance(host: host, now: now)
    }

    private mutating func restart(in window: Node) {
        state = .searching(window: window, stack: [Pending(node: window, depth: 0)], visits: 0)
    }

    /// Runs one time slice of the walk, keeping its stack for the next poll when time runs out.
    private mutating func advance(host: Host, now: () -> Date) -> Resolution? {
        guard case .searching(let window, var stack, var visits) = state else {
            return nil
        }
        let deadline = now().addingTimeInterval(Self.sliceDuration)
        while let next = stack.last, visits < Self.maximumVisits, now() < deadline {
            stack.removeLast()
            visits += 1
            if host.isFocusedEditableField(next.node) {
                state = .found(window: window, field: next.node)
                return .found(next.node)
            }
            if next.depth < Self.maximumDepth {
                stack.append(contentsOf: host.children(next.node).map { Pending(node: $0, depth: next.depth + 1) })
            }
        }
        if stack.isEmpty || visits >= Self.maximumVisits {
            state = .coolingDown(window: window, retryAt: now().addingTimeInterval(Self.retryDelay))
        } else {
            state = .searching(window: window, stack: stack, visits: visits)
        }
        return nil
    }
}

extension CodexFocusSearch.Pending: Equatable where Node: Equatable {}
extension CodexFocusSearch.State: Equatable where Node: Equatable {}
extension CodexFocusSearch.Resolution: Equatable where Node: Equatable {}
