import Foundation

/// A tree the walker can traverse. The AX implementation is one conformance;
/// `SyntheticTreeSource` is the other, and it is what lets the bounding logic be
/// tested against deliberately hostile shapes without needing a hostile app.
protocol TreeSource {
    associatedtype Node: Hashable

    func describe(_ node: Node, depth: Int, path: [Int]) -> [String: JSON]
    func childCount(of node: Node) -> Int
    func children(of node: Node, limit: Int) -> [Node]
}

struct WalkLimits {
    /// Hard ceiling on recursion; also caps stack depth.
    var maxDepth: Int = 12
    /// Total nodes described. Depth alone does not bound a wide tree.
    var maxNodes: Int = 4000
    /// Children read per node.
    var maxChildren: Int = 100
    /// Wall clock. Each individual read is separately bounded by the AX
    /// messaging timeout, so the worst case is deadline + one timeout.
    var budget: TimeInterval = 20
}

enum TruncationReason: String, CaseIterable {
    case depth, budget, children, deadline, cycle
}

/// Bounded depth-first walker.
///
/// Every stopping condition is recorded rather than silently applied, so a
/// partial dump is always distinguishable from a complete one.
final class BoundedWalker<Source: TreeSource> {
    private let source: Source
    private let limits: WalkLimits
    private let deadline: Date
    private var ancestors: Set<Source.Node> = []

    private(set) var nodesVisited = 0
    private(set) var maxDepthReached = 0
    private(set) var truncations: [TruncationReason: Int] = [:]

    init(source: Source, limits: WalkLimits, now: Date = Date()) {
        self.source = source
        self.limits = limits
        self.deadline = now.addingTimeInterval(limits.budget)
    }

    var isComplete: Bool { truncations.isEmpty }

    var statistics: JSON {
        var counts: [String: JSON] = [:]
        for reason in TruncationReason.allCases where truncations[reason] != nil {
            counts[reason.rawValue] = .int(truncations[reason]!)
        }
        return .object([
            "nodesVisited": .int(nodesVisited),
            "maxDepthReached": .int(maxDepthReached),
            "complete": .bool(isComplete),
            "truncations": .object(counts),
            "limits": .object([
                "maxDepth": .int(limits.maxDepth),
                "maxNodes": .int(limits.maxNodes),
                "maxChildren": .int(limits.maxChildren),
                "budgetSeconds": .number(limits.budget),
            ]),
        ])
    }

    func walk(_ node: Source.Node) -> JSON {
        walk(node, depth: 0, path: [])
    }

    private func walk(_ node: Source.Node, depth: Int, path: [Int]) -> JSON {
        if Date() >= deadline { return stop(.deadline, path: path) }
        if nodesVisited >= limits.maxNodes { return stop(.budget, path: path) }
        if ancestors.contains(node) { return stop(.cycle, path: path) }

        nodesVisited += 1
        maxDepthReached = max(maxDepthReached, depth)

        var object = source.describe(node, depth: depth, path: path)
        object["depth"] = .int(depth)
        object["path"] = .string(Self.render(path: path))

        let total = source.childCount(of: node)
        object["childCount"] = .int(total)

        guard total > 0 else { return .object(object) }
        guard depth < limits.maxDepth else { return .object(mark(object, .depth)) }

        let limit = min(total, limits.maxChildren)
        if limit < total { object = mark(object, .children) }

        let children = source.children(of: node, limit: limit)
        guard !children.isEmpty else { return .object(object) }

        ancestors.insert(node)
        defer { ancestors.remove(node) }
        object["children"] = .array(children.enumerated().map { index, child in
            walk(child, depth: depth + 1, path: path + [index])
        })
        return .object(object)
    }

    private func stop(_ reason: TruncationReason, path: [Int]) -> JSON {
        truncations[reason, default: 0] += 1
        return .object(["truncated": .string(reason.rawValue), "path": .string(Self.render(path: path))])
    }

    private func mark(_ object: [String: JSON], _ reason: TruncationReason) -> [String: JSON] {
        truncations[reason, default: 0] += 1
        var copy = object
        copy["truncated"] = .string(reason.rawValue)
        return copy
    }

    static func render(path: [Int]) -> String {
        path.isEmpty ? "root" : "root/" + path.map(String.init).joined(separator: "/")
    }
}
