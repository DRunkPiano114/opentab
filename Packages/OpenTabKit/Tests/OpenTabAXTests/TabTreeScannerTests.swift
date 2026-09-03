import XCTest
@testable import OpenTabAX

/// A tree built from a spec table, plus the three hostile shapes the walker
/// has to survive: unbounded depth, unbounded breadth, and a child that points
/// back at an ancestor.
///
/// Every title in this file is invented. No accessibility dump is checked into
/// the repository and no real window title appears in any fixture (L16); the
/// dumps supplied the *shape* only — role chains, depths, and which attribute
/// carries the title on which app.
private final class SyntheticTree: TabTreeSource {
    typealias Node = Int

    struct Spec {
        var role: String
        var subrole = ""
        var title = ""
        var description = ""
        var selected = false
        var children: [Int] = []
    }

    var nodes: [Int: Spec]
    /// Ids with no spec: they read as unreadable, like a node that stopped
    /// answering mid-walk.
    private(set) var attributeReads = 0
    private(set) var childReads = 0

    init(_ nodes: [Int: Spec]) { self.nodes = nodes }

    func attributes(of node: Int) -> TabNodeAttributes? {
        attributeReads += 1
        guard let spec = nodes[node] else { return nil }
        return TabNodeAttributes(role: spec.role, subrole: spec.subrole, title: spec.title,
                                 description: spec.description, isSelected: spec.selected)
    }

    func children(of node: Int, limit: Int) -> [Int] {
        childReads += 1
        return Array((nodes[node]?.children ?? []).prefix(limit))
    }
}

/// An endlessly deep, endlessly wide tree. Ids are minted on demand, so no
/// bound in the scanner can be satisfied by the fixture running out.
private final class UnboundedTree: TabTreeSource {
    typealias Node = Int

    let branching: Int
    private var next = 1
    private(set) var attributeReads = 0

    init(branching: Int) { self.branching = branching }

    func attributes(of node: Int) -> TabNodeAttributes? {
        attributeReads += 1
        return TabNodeAttributes(role: "AXGroup", subrole: "", title: "", description: "",
                                 isSelected: false)
    }

    func children(of node: Int, limit: Int) -> [Int] {
        (0..<min(branching, limit)).map { _ in
            defer { next += 1 }
            return next
        }
    }
}

/// Every node's only child is the root.
private struct CyclicTree: TabTreeSource {
    typealias Node = Int

    func attributes(of node: Int) -> TabNodeAttributes? {
        TabNodeAttributes(role: "AXGroup", subrole: "", title: "", description: "", isSelected: false)
    }

    func children(of node: Int, limit: Int) -> [Int] { [0] }
}

final class TabTreeScannerTests: XCTestCase {
    private let never = ContinuousClock.now + .seconds(3_600)

    // MARK: Depth

    /// Chrome's measured chain: `AXWindow > AXGroup ×6 > AXTabGroup >
    /// AXRadioButton`, so the tab button sits at depth 8 from the window.
    private func chromeShaped(tabCount: Int, activeIndex: Int) -> SyntheticTree {
        var nodes: [Int: SyntheticTree.Spec] = [:]
        for depth in 0..<7 {
            nodes[depth] = SyntheticTree.Spec(role: depth == 0 ? "AXWindow" : "AXGroup",
                                              children: [depth + 1])
        }
        let tabIDs = Array(100..<(100 + tabCount))
        nodes[7] = SyntheticTree.Spec(role: "AXTabGroup", children: tabIDs)
        for (offset, id) in tabIDs.enumerated() {
            nodes[id] = SyntheticTree.Spec(role: "AXRadioButton", subrole: "AXTabButton",
                                           // Chrome leaves AXTitle an empty string.
                                           title: "", description: "page \(offset)",
                                           selected: offset == activeIndex,
                                           children: [id + 1_000])
            nodes[id + 1_000] = SyntheticTree.Spec(role: "AXButton")
        }
        return SyntheticTree(nodes)
    }

    func testFindsChromiumTabGroupAtDepthSeven() {
        let tree = chromeShaped(tabCount: 3, activeIndex: 1)
        let result = TabTreeScanner.scan(window: 0, source: tree, deadline: never)
        XCTAssertEqual(result.tabs.count, 3)
        XCTAssertEqual(result.tabs.map { $0.attributes.displayTitle }, ["page 0", "page 1", "page 2"])
        XCTAssertEqual(result.tabs.map { $0.attributes.isSelected }, [false, true, false])
    }

    func testDepthCapOfSevenMissesChromium() {
        let tree = chromeShaped(tabCount: 3, activeIndex: 0)
        let limits = TabScanLimits(maxDepth: 7)
        let result = TabTreeScanner.scan(window: 0, source: tree, limits: limits, deadline: never)
        XCTAssertTrue(result.tabs.isEmpty)
        XCTAssertTrue(result.stops.contains(.depth))
    }

    func testDepthCapStopsUnboundedDepth() {
        let tree = UnboundedTree(branching: 1)
        let result = TabTreeScanner.scan(window: 0, source: tree, deadline: never)
        XCTAssertTrue(result.stops.contains(.depth))
        // Window plus one node per level.
        XCTAssertEqual(result.nodesVisited, 9)
    }

    // MARK: Budget and fan-out

    func testNodeBudgetStopsUnboundedBreadth() {
        let tree = UnboundedTree(branching: 50)
        let limits = TabScanLimits(maxNodes: 120)
        let result = TabTreeScanner.scan(window: 0, source: tree, limits: limits, deadline: never)
        XCTAssertTrue(result.stops.contains(.nodes))
        XCTAssertEqual(result.nodesVisited, 120)
        XCTAssertLessThanOrEqual(tree.attributeReads, 120)
    }

    func testChildLimitCapsFanOut() {
        let tree = UnboundedTree(branching: 500)
        let limits = TabScanLimits(maxDepth: 1, maxNodes: 10_000, maxChildren: 8)
        let result = TabTreeScanner.scan(window: 0, source: tree, limits: limits, deadline: never)
        XCTAssertTrue(result.stops.contains(.children))
        XCTAssertEqual(result.nodesVisited, 9)
    }

    // MARK: Cycles

    func testCycleTerminates() {
        let result = TabTreeScanner.scan(window: 0, source: CyclicTree(), deadline: never)
        XCTAssertTrue(result.stops.contains(.cycle))
        XCTAssertEqual(result.nodesVisited, 1)
    }

    func testDiamondIsVisitedOnce() {
        let tree = SyntheticTree([
            0: .init(role: "AXWindow", children: [1, 2]),
            1: .init(role: "AXGroup", children: [3]),
            2: .init(role: "AXGroup", children: [3]),
            3: .init(role: "AXTabGroup", children: [4]),
            4: .init(role: "AXRadioButton", subrole: "AXTabButton", title: "one"),
        ])
        let result = TabTreeScanner.scan(window: 0, source: tree, deadline: never)
        XCTAssertEqual(result.tabs.count, 1)
        XCTAssertTrue(result.stops.contains(.cycle))
    }

    // MARK: Deadline

    func testDeadlineStopsBeforeTheFirstNode() {
        let tree = UnboundedTree(branching: 4)
        var ticks = 0
        let start = ContinuousClock.now
        let result = TabTreeScanner.scan(window: 0, source: tree, deadline: start + .seconds(1)) {
            defer { ticks += 1 }
            return ticks == 0 ? start : start + .seconds(2)
        }
        XCTAssertTrue(result.stops.contains(.deadline))
        XCTAssertEqual(result.nodesVisited, 1)
    }

    // MARK: Reading a tab

    func testFinderShapedTabUsesItsOwnTitle() {
        let tree = SyntheticTree([
            0: .init(role: "AXWindow", children: [1]),
            1: .init(role: "AXTabGroup", children: [2, 3]),
            2: .init(role: "AXRadioButton", subrole: "AXTabButton", title: "left", selected: true),
            3: .init(role: "AXRadioButton", subrole: "AXTabButton", title: "right"),
        ])
        let result = TabTreeScanner.scan(window: 0, source: tree, deadline: never)
        XCTAssertEqual(result.tabs.map { $0.attributes.displayTitle }, ["left", "right"])
    }

    /// The `title ?? description` spelling would take the empty string here.
    func testEmptyTitleFallsBackToDescription() {
        let attributes = TabNodeAttributes(role: "AXRadioButton", subrole: "AXTabButton",
                                           title: "", description: "from description",
                                           isSelected: false)
        XCTAssertEqual(attributes.displayTitle, "from description")
    }

    func testTabButtonChildrenAreNotWalked() {
        let tree = SyntheticTree([
            0: .init(role: "AXWindow", children: [1]),
            1: .init(role: "AXTabGroup", children: [2]),
            2: .init(role: "AXRadioButton", subrole: "AXTabButton", title: "one", children: [3]),
            3: .init(role: "AXButton"),
        ])
        let result = TabTreeScanner.scan(window: 0, source: tree, deadline: never)
        XCTAssertEqual(result.tabs.count, 1)
        XCTAssertEqual(result.nodesVisited, 3)
    }

    func testOpaqueRolesAreNotDescended() {
        let tree = SyntheticTree([
            0: .init(role: "AXWindow", children: [1, 4]),
            1: .init(role: "AXWebArea", children: [2]),
            2: .init(role: "AXTabGroup", children: [3]),
            3: .init(role: "AXRadioButton", subrole: "AXTabButton", title: "buried"),
            4: .init(role: "AXTabGroup", children: [5]),
            5: .init(role: "AXRadioButton", subrole: "AXTabButton", title: "reachable"),
        ])
        let result = TabTreeScanner.scan(window: 0, source: tree, deadline: never)
        XCTAssertEqual(result.tabs.map { $0.attributes.displayTitle }, ["reachable"])
    }

    func testUnreadableNodeDoesNotStopTheWalk() {
        let tree = SyntheticTree([
            0: .init(role: "AXWindow", children: [1, 2]),
            // 1 has no spec: it reads as unreadable.
            2: .init(role: "AXTabGroup", children: [3]),
            3: .init(role: "AXRadioButton", subrole: "AXTabButton", title: "after the gap"),
        ])
        let result = TabTreeScanner.scan(window: 0, source: tree, deadline: never)
        XCTAssertEqual(result.tabs.count, 1)
        XCTAssertTrue(result.stops.contains(.unreadable))
    }

    func testTabsComeBackInDocumentOrder() {
        var nodes: [Int: SyntheticTree.Spec] = [
            0: .init(role: "AXWindow", children: [1]),
            1: .init(role: "AXTabGroup", children: [10, 11, 12, 13]),
        ]
        for (offset, id) in [10, 11, 12, 13].enumerated() {
            nodes[id] = .init(role: "AXRadioButton", subrole: "AXTabButton", title: "t\(offset)")
        }
        let result = TabTreeScanner.scan(window: 0, source: SyntheticTree(nodes), deadline: never)
        XCTAssertEqual(result.tabs.map { $0.attributes.displayTitle }, ["t0", "t1", "t2", "t3"])
    }
}

/// A tab group whose tabs are reachable only through `AXTabs`: they are not
/// among its children, and they carry no subrole. Measured on iTerm2.
private struct DeclaredTabsTree: TabTreeSource {
    typealias Node = Int

    let roles: [Int: String]
    let declared: [Int: [Int]]

    func attributes(of node: Int) -> TabNodeAttributes? {
        guard let role = roles[node] else { return nil }
        return TabNodeAttributes(role: role, subrole: "", title: "tab \(node)", description: "",
                                 isSelected: node == 11)
    }

    func children(of node: Int, limit: Int) -> [Int] {
        node == 0 ? [1] : []
    }

    func declaredTabs(of node: Int, limit: Int) -> [Int] {
        Array((declared[node] ?? []).prefix(limit))
    }
}

final class DeclaredTabsScannerTests: XCTestCase {
    private let never = ContinuousClock.now + .seconds(3_600)

    private var tree: DeclaredTabsTree {
        DeclaredTabsTree(roles: [0: "AXWindow", 1: "AXTabGroup", 10: "AXRadioButton", 11: "AXRadioButton"],
                         declared: [1: [10, 11]])
    }

    func testTabGroupTabsAreReadWhenTheWalkFindsNone() {
        let result = TabTreeScanner.scan(window: 0, source: tree, deadline: never)
        XCTAssertEqual(result.tabs.map { $0.attributes.displayTitle }, ["tab 10", "tab 11"])
        XCTAssertEqual(result.tabs.map { $0.attributes.isSelected }, [false, true])
        XCTAssertTrue(result.usedDeclaredTabs)
    }

    /// The fallback costs nothing when the walk succeeds, which is what keeps
    /// it off the Chromium path.
    func testDeclaredTabsAreNotConsultedWhenTheWalkFoundTabs() {
        let tree = SyntheticTree([
            0: .init(role: "AXWindow", children: [1]),
            1: .init(role: "AXTabGroup", children: [2]),
            2: .init(role: "AXRadioButton", subrole: "AXTabButton", title: "walked"),
        ])
        let result = TabTreeScanner.scan(window: 0, source: tree, deadline: never)
        XCTAssertEqual(result.tabs.map { $0.attributes.displayTitle }, ["walked"])
        XCTAssertFalse(result.usedDeclaredTabs)
    }

    /// A group that names something that is not a tab element is ignored
    /// rather than turned into a row.
    func testDeclaredElementsThatAreNotTabsAreIgnored() {
        let tree = DeclaredTabsTree(roles: [0: "AXWindow", 1: "AXTabGroup", 10: "AXGroup"],
                                    declared: [1: [10]])
        let result = TabTreeScanner.scan(window: 0, source: tree, deadline: never)
        XCTAssertTrue(result.tabs.isEmpty)
        XCTAssertFalse(result.usedDeclaredTabs)
    }

    func testAWindowWithNoTabGroupAsksNothing() {
        let tree = DeclaredTabsTree(roles: [0: "AXWindow", 1: "AXGroup"], declared: [1: [10, 11]])
        let result = TabTreeScanner.scan(window: 0, source: tree, deadline: never)
        XCTAssertTrue(result.tabs.isEmpty)
    }
}
