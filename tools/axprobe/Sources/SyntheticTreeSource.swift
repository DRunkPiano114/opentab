import Foundation

/// A configurable hostile tree: unbounded depth, unbounded breadth, slow nodes,
/// and parent cycles. It exists so the walker's stopping conditions can be
/// exercised deterministically, with no permission and no cooperating app.
final class SyntheticTreeSource: TreeSource {
    typealias Node = Int

    let branching: Int
    let treeDepth: Int
    /// Simulates an app that answers slowly but never quite times out.
    let delayPerNode: TimeInterval
    /// Once a node id reaches this value, its only child is the root.
    let cycleBackAfter: Int?

    private var nextID = 1
    private var depths: [Int: Int] = [0: 0]
    private(set) var describeCount = 0

    init(branching: Int, treeDepth: Int = .max,
         delayPerNode: TimeInterval = 0, cycleBackAfter: Int? = nil) {
        self.branching = branching
        self.treeDepth = treeDepth
        self.delayPerNode = delayPerNode
        self.cycleBackAfter = cycleBackAfter
    }

    func describe(_ node: Int, depth: Int, path: [Int]) -> [String: JSON] {
        describeCount += 1
        if delayPerNode > 0 { Thread.sleep(forTimeInterval: delayPerNode) }
        return ["id": .int(node)]
    }

    func childCount(of node: Int) -> Int {
        if cycleBackAfter != nil { return branching }
        return (depths[node] ?? 0) >= treeDepth ? 0 : branching
    }

    func children(of node: Int, limit: Int) -> [Int] {
        if let cycleBackAfter, node >= cycleBackAfter { return [0] }
        let depth = (depths[node] ?? 0) + 1
        return (0..<limit).map { _ in
            let id = nextID
            nextID += 1
            depths[id] = depth
            return id
        }
    }
}
