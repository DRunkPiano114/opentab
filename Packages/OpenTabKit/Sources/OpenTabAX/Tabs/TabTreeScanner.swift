import Foundation

/// The subrole every tab button carries. Native AppKit tab groups (Finder,
/// Ghostty) and Chromium's own tab strip both report `AXRadioButton` +
/// `AXTabButton`, so one structural predicate replaces a per-app table of
/// role triples (appendix h §3).
let axTabButtonSubrole = "AXTabButton"

/// What one node contributes to the tab search.
///
/// Only `role`, `subrole` and `isSelected` are branched on: E1 clears
/// `AXRole`, `AXSubrole` and a boolean `AXValue` for logic and rules out
/// every string that carries display text (L3). `title` and `description`
/// are localised and feed nothing but the row label.
struct TabNodeAttributes: Sendable, Equatable {
    var role: String
    var subrole: String
    var title: String
    var description: String
    /// `AXValue`, which is a real boolean on a tab button and is `true` on
    /// exactly one tab per window.
    var isSelected: Bool

    /// Chrome's `AXTitle` is an empty string rather than absent, and the page
    /// title lives in `AXDescription`; `title ?? description` would reliably
    /// pick the empty one (L11).
    var displayTitle: String { title.isEmpty ? description : title }
}

/// The tree the scanner walks. The accessibility hierarchy is one
/// implementation; a synthetic tree is the other, which is what lets the
/// stopping conditions be tested with no permission and no cooperating app.
protocol TabTreeSource {
    associatedtype Node: Hashable
    /// `nil` when the node could not be read at all.
    func attributes(of node: Node) -> TabNodeAttributes?
    func children(of node: Node, limit: Int) -> [Node]
}

/// Why a scan stopped short. Recorded for diagnostics; a scan that hit a
/// limit still returns the tabs it found.
enum TabScanStop: String, Sendable, Comparable {
    case depth, nodes, children, deadline, cycle, unreadable

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct TabScanLimits: Sendable {
    /// Measured from the window element, which is depth 0. Chrome's tab
    /// buttons sit at exactly 8 (`AXWindow > AXGroup ×6 > AXTabGroup >
    /// AXRadioButton`) and Finder's at 2, so a cap of 6 finds Finder and
    /// silently misses every Chromium tab.
    var maxDepth = 8
    /// Whole-window ceiling. A warm Chrome window costs 76-106 nodes.
    var maxNodes = 600
    var maxChildren = 100

    init(maxDepth: Int = 8, maxNodes: Int = 600, maxChildren: Int = 100) {
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.maxChildren = maxChildren
    }
}

struct TabScanResult<Node> {
    var tabs: [(node: Node, attributes: TabNodeAttributes)] = []
    var nodesVisited = 0
    var stops: Set<TabScanStop> = []
}

enum TabTreeScanner {
    /// Roles the walk never descends into: large, uniform, and structurally
    /// incapable of holding a tab strip. Without this one web area eats the
    /// whole node budget before the tab strip is reached.
    static let opaqueRoles: Set<String> = [
        "AXWebArea", "AXTable", "AXOutline", "AXList", "AXGrid", "AXTextArea",
        "AXTextField", "AXStaticText", "AXImage", "AXMenu", "AXMenuBar",
        "AXMenuItem", "AXMenuButton", "AXCell", "AXRow", "AXColumn",
    ]

    /// Depth-first, in document order, bounded four ways: depth, node budget,
    /// child fan-out and a wall-clock deadline. Nodes already seen are not
    /// visited again, so a tree that points back at itself terminates.
    ///
    /// `now` is injectable so the deadline can be exercised without sleeping.
    static func scan<Source: TabTreeSource>(
        window: Source.Node,
        source: Source,
        limits: TabScanLimits = TabScanLimits(),
        deadline: ContinuousClock.Instant,
        now: () -> ContinuousClock.Instant = { .now }
    ) -> TabScanResult<Source.Node> {
        var result = TabScanResult<Source.Node>()
        var visited: Set<Source.Node> = [window]
        var stack: [(node: Source.Node, depth: Int)] = [(window, 0)]

        while let frame = stack.popLast() {
            guard now() < deadline else {
                result.stops.insert(.deadline)
                return result
            }
            guard result.nodesVisited < limits.maxNodes else {
                result.stops.insert(.nodes)
                return result
            }
            result.nodesVisited += 1

            guard let attributes = source.attributes(of: frame.node) else {
                result.stops.insert(.unreadable)
                continue
            }
            if attributes.subrole == axTabButtonSubrole {
                result.tabs.append((frame.node, attributes))
                // A tab button's only child is its close button.
                continue
            }
            guard frame.depth < limits.maxDepth else {
                result.stops.insert(.depth)
                continue
            }
            guard !opaqueRoles.contains(attributes.role) else { continue }

            let children = source.children(of: frame.node, limit: limits.maxChildren)
            if children.count >= limits.maxChildren { result.stops.insert(.children) }
            // Reversed, so popping the stack yields document order.
            for child in children.reversed() {
                guard visited.insert(child).inserted else {
                    result.stops.insert(.cycle)
                    continue
                }
                stack.append((child, frame.depth + 1))
            }
        }
        return result
    }
}
