import XCTest
@testable import Cotabby

/// Drives `CodexFocusSearch` against a scripted tree of integer nodes and a hand-stepped clock, so
/// every transition of the resumable walk is checked without a live Accessibility tree.
@MainActor
final class CodexFocusSearchTests: XCTestCase {
    private typealias Search = CodexFocusSearch<Int>

    /// A scripted window: children by node, the set of editable nodes, and the one focused node.
    private final class Tree {
        var children: [Int: [Int]] = [:]
        var editable: Set<Int> = []
        var focused: Int?
        /// Every node the walk asked about, in order.
        var visited: [Int] = []
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        /// Seconds the clock advances on each read, so a test can make a slice run out.
        var secondsPerClockRead: TimeInterval = 0

        var host: Search.Host {
            Search.Host(
                isSameNode: { $0 == $1 },
                isFocused: { [unowned self] in self.focused == $0 },
                isFocusedEditableField: { [unowned self] node in
                    self.visited.append(node)
                    return self.editable.contains(node) && self.focused == node
                },
                children: { [unowned self] in self.children[$0] ?? [] }
            )
        }

        func clock() -> Date {
            now.addTimeInterval(secondsPerClockRead)
            return now
        }
    }

    /// Window 1 holds a group 2 and a toolbar 3; the composer 4 sits under the group.
    private func composerTree() -> Tree {
        let tree = Tree()
        tree.children = [1: [2, 3], 2: [4]]
        tree.editable = [4]
        tree.focused = 4
        return tree
    }

    private func poll(_ search: inout Search, window: Int = 1, tree: Tree) -> Search.Resolution? {
        search.focusedField(in: window, host: tree.host, now: tree.clock)
    }

    func test_startsInactive() {
        XCTAssertEqual(Search().state, .inactive)
    }

    func test_findsTheFocusedEditableDescendant() {
        let tree = composerTree()
        var search = Search()

        XCTAssertEqual(poll(&search, tree: tree), .found(4))
        XCTAssertEqual(search.state, .found(window: 1, field: 4))
    }

    /// Depth-first, last child first: the walk pops the most recently pushed node.
    func test_walksDepthFirstFromTheWindow() {
        let tree = composerTree()
        tree.focused = nil
        var search = Search()

        _ = poll(&search, tree: tree)

        XCTAssertEqual(tree.visited, [1, 3, 2, 4])
    }

    func test_anEditableNodeThatIsNotFocusedIsNotTheField() {
        let tree = composerTree()
        tree.editable = [3, 4]
        var search = Search()

        XCTAssertEqual(poll(&search, tree: tree), .found(4))
    }

    func test_aFocusedNodeThatIsNotEditableIsNotTheField() {
        let tree = composerTree()
        tree.focused = 3
        var search = Search()

        XCTAssertNil(poll(&search, tree: tree))
    }

    func test_reusesTheFoundFieldWithoutWalkingWhileItStaysFocused() {
        let tree = composerTree()
        var search = Search()
        _ = poll(&search, tree: tree)
        tree.visited = []

        XCTAssertEqual(poll(&search, tree: tree), .reused(4))
        XCTAssertEqual(tree.visited, [])
    }

    func test_aFieldThatLostFocusIsSearchedForAgainAtOnce() {
        let tree = composerTree()
        tree.children[3] = [5]
        tree.editable = [4, 5]
        var search = Search()
        _ = poll(&search, tree: tree)

        tree.focused = 5

        XCTAssertEqual(poll(&search, tree: tree), .found(5))
        XCTAssertEqual(search.state, .found(window: 1, field: 5))
    }

    func test_anExhaustedWalkCoolsDownForTheRetryDelay() {
        let tree = composerTree()
        tree.focused = nil
        var search = Search()

        XCTAssertNil(poll(&search, tree: tree))

        XCTAssertEqual(search.state, .coolingDown(window: 1, retryAt: tree.now.addingTimeInterval(Search.retryDelay)))
    }

    func test_noWalkRunsWhileCoolingDown() {
        let tree = composerTree()
        tree.focused = nil
        var search = Search()
        _ = poll(&search, tree: tree)
        tree.visited = []
        tree.focused = 4

        tree.now.addTimeInterval(Search.retryDelay - 0.01)

        XCTAssertNil(poll(&search, tree: tree))
        XCTAssertEqual(tree.visited, [])
    }

    func test_theWalkRestartsOnceTheCooldownHasPassed() {
        let tree = composerTree()
        tree.focused = nil
        var search = Search()
        _ = poll(&search, tree: tree)
        tree.focused = 4

        tree.now.addTimeInterval(Search.retryDelay)

        XCTAssertEqual(poll(&search, tree: tree), .found(4))
    }

    /// A cooldown belongs to the window that was walked; a new window is searched immediately.
    func test_aNewWindowRestartsTheSearchDuringACooldown() {
        let tree = composerTree()
        tree.focused = nil
        var search = Search()
        _ = poll(&search, tree: tree)
        tree.children[10] = [11]
        tree.editable.insert(11)
        tree.focused = 11

        XCTAssertEqual(poll(&search, window: 10, tree: tree), .found(11))
        XCTAssertEqual(search.state, .found(window: 10, field: 11))
    }

    /// The old window's field may still report focused; it must not be served for the new window.
    func test_aNewWindowDropsTheFoundField() {
        let tree = composerTree()
        var search = Search()
        _ = poll(&search, tree: tree)

        XCTAssertNil(poll(&search, window: 10, tree: tree))
        XCTAssertEqual(tree.visited.last, 10)
    }

    func test_aSliceThatRunsOutOfTimeResumesWhereItStopped() {
        let tree = composerTree()
        // Each clock read costs 0.6 of a slice. The deadline is set by the first read, the second
        // (before the first node) is still inside it and the third is past it: one node per poll.
        tree.secondsPerClockRead = Search.sliceDuration * 0.6
        var search = Search()

        XCTAssertNil(poll(&search, tree: tree))
        XCTAssertEqual(tree.visited, [1])
        XCTAssertEqual(
            search.state,
            .searching(window: 1, stack: [Search.Pending(node: 2, depth: 1), Search.Pending(node: 3, depth: 1)], visits: 1)
        )

        XCTAssertNil(poll(&search, tree: tree))
        XCTAssertEqual(tree.visited, [1, 3])

        XCTAssertNil(poll(&search, tree: tree))
        XCTAssertEqual(poll(&search, tree: tree), .found(4))
        XCTAssertEqual(tree.visited, [1, 3, 2, 4])
    }

    /// The budget ends the walk with nodes still waiting, and the cooldown drops them.
    func test_theVisitBudgetEndsAWalkOfAWindowTooLargeToFinish() {
        let tree = Tree()
        // A window with more children than one walk may visit, none editable.
        let host = Search.Host(
            isSameNode: { $0 == $1 },
            isFocused: { _ in false },
            isFocusedEditableField: { tree.visited.append($0); return false },
            children: { $0 == 0 ? Array(1...(Search.maximumVisits * 2)) : [] }
        )
        var search = Search()

        XCTAssertNil(search.focusedField(in: 0, host: host, now: tree.clock))

        XCTAssertEqual(tree.visited.count, Search.maximumVisits)
        XCTAssertEqual(search.state, .coolingDown(window: 0, retryAt: tree.now.addingTimeInterval(Search.retryDelay)))
    }

    func test_childrenBelowTheDepthLimitAreNotFollowed() {
        let tree = Tree()
        // A chain 0 -> 1 -> 2 -> ... one node per depth.
        let host = Search.Host(
            isSameNode: { $0 == $1 },
            isFocused: { _ in false },
            isFocusedEditableField: { tree.visited.append($0); return false },
            children: { [$0 + 1] }
        )
        var search = Search()

        XCTAssertNil(search.focusedField(in: 0, host: host, now: tree.clock))

        XCTAssertEqual(tree.visited.last, Search.maximumDepth)
        XCTAssertEqual(tree.visited.count, Search.maximumDepth + 1)
    }

    func test_deactivateForgetsTheFoundField() {
        let tree = composerTree()
        var search = Search()
        _ = poll(&search, tree: tree)

        search.deactivate()

        XCTAssertEqual(search.state, .inactive)
        XCTAssertEqual(poll(&search, tree: tree), .found(4), "a fresh walk, not a reuse")
    }
}
