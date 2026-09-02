import Foundation

/// Verifies the walker's bounding logic. Needs no Accessibility permission and
/// touches no other process, so it is the part of this tool that can be checked
/// on every build.
enum CommandSelfTest {
    private struct Check {
        let name: String
        let passed: Bool
        let detail: String
    }

    static func run(output: Output) throws -> Int32 {
        var checks: [Check] = []

        checks.append(depthCap())
        checks.append(breadthCap())
        checks.append(nodeBudget())
        checks.append(wallClockBudget())
        checks.append(cycleDetection())
        checks.append(jsonRoundTrip())

        let failures = checks.filter { !$0.passed }
        let json = JSON.object([
            "command": .string("selftest"),
            "passed": .int(checks.count - failures.count),
            "failed": .int(failures.count),
            "checks": .array(checks.map {
                .object(["name": .string($0.name), "passed": .bool($0.passed),
                         "detail": .string($0.detail)])
            }),
        ])

        var lines = ["axprobe selftest — walker bounding logic", ""]
        for check in checks {
            lines.append("  \(check.passed ? "PASS" : "FAIL")  \(check.name): \(check.detail)")
        }
        lines.append("")
        lines.append(failures.isEmpty
            ? "All \(checks.count) checks passed."
            : "\(failures.count) of \(checks.count) checks FAILED.")

        try output.write("selftest", json: json, summary: lines.joined(separator: "\n"))
        return failures.isEmpty ? 0 : 1
    }

    /// An infinitely deep tree must stop at maxDepth and say so.
    private static func depthCap() -> Check {
        let source = SyntheticTreeSource(branching: 1)
        var limits = WalkLimits()
        limits.maxDepth = 5
        limits.maxNodes = 10_000
        let walker = BoundedWalker(source: source, limits: limits)
        _ = walker.walk(0)
        let passed = walker.maxDepthReached == 5
            && walker.nodesVisited == 6
            && walker.truncations[.depth] == 1
        return Check(name: "depth cap",
                     passed: passed,
                     detail: "maxDepth=5 -> visited \(walker.nodesVisited), deepest \(walker.maxDepthReached), truncations \(render(walker.truncations))")
    }

    /// A node with far more children than the cap yields exactly the cap.
    private static func breadthCap() -> Check {
        let source = SyntheticTreeSource(branching: 1000, treeDepth: 1)
        var limits = WalkLimits()
        limits.maxChildren = 10
        limits.maxNodes = 10_000
        let walker = BoundedWalker(source: source, limits: limits)
        _ = walker.walk(0)
        let passed = walker.nodesVisited == 11 && walker.truncations[.children] == 1
        return Check(name: "breadth cap",
                     passed: passed,
                     detail: "1000 children, maxChildren=10 -> visited \(walker.nodesVisited), truncations \(render(walker.truncations))")
    }

    /// Depth alone cannot bound a wide tree; the node budget must.
    private static func nodeBudget() -> Check {
        let source = SyntheticTreeSource(branching: 8)
        var limits = WalkLimits()
        limits.maxDepth = 64
        limits.maxNodes = 50
        let walker = BoundedWalker(source: source, limits: limits)
        _ = walker.walk(0)
        let passed = walker.nodesVisited == 50 && (walker.truncations[.budget] ?? 0) > 0
        return Check(name: "node budget",
                     passed: passed,
                     detail: "maxNodes=50 -> visited \(walker.nodesVisited), truncations \(render(walker.truncations))")
    }

    /// A slow app must not hold the walk open indefinitely.
    private static func wallClockBudget() -> Check {
        let source = SyntheticTreeSource(branching: 4, delayPerNode: 0.01)
        var limits = WalkLimits()
        limits.maxDepth = 64
        limits.maxNodes = 100_000
        limits.budget = 0.2
        let started = Date()
        let walker = BoundedWalker(source: source, limits: limits)
        _ = walker.walk(0)
        let elapsed = Date().timeIntervalSince(started)
        let passed = (walker.truncations[.deadline] ?? 0) > 0 && elapsed < 2.0
        return Check(name: "wall-clock budget",
                     passed: passed,
                     detail: String(format: "budget=0.2s -> stopped after %.2fs, visited %d, truncations %@",
                                    elapsed, walker.nodesVisited, render(walker.truncations)))
    }

    /// A child pointing back at an ancestor must terminate, not recurse forever.
    private static func cycleDetection() -> Check {
        let source = SyntheticTreeSource(branching: 1, cycleBackAfter: 3)
        var limits = WalkLimits()
        limits.maxDepth = 64
        limits.maxNodes = 10_000
        limits.budget = 5
        let walker = BoundedWalker(source: source, limits: limits)
        _ = walker.walk(0)
        let passed = (walker.truncations[.cycle] ?? 0) > 0
            && walker.truncations[.budget] == nil
            && walker.truncations[.deadline] == nil
        return Check(name: "cycle detection",
                     passed: passed,
                     detail: "child points at root -> visited \(walker.nodesVisited), truncations \(render(walker.truncations))")
    }

    /// A truncated walk must still produce parseable JSON, not a broken file.
    private static func jsonRoundTrip() -> Check {
        let source = SyntheticTreeSource(branching: 3)
        var limits = WalkLimits()
        limits.maxNodes = 40
        let walker = BoundedWalker(source: source, limits: limits)
        let tree = walker.walk(0)
        do {
            let data = try tree.encoded()
            _ = try JSONSerialization.jsonObject(with: data)
            return Check(name: "partial output is valid JSON",
                         passed: true, detail: "\(data.count) bytes parsed")
        } catch {
            return Check(name: "partial output is valid JSON",
                         passed: false, detail: "\(error)")
        }
    }

    private static func render(_ truncations: [TruncationReason: Int]) -> String {
        guard !truncations.isEmpty else { return "none" }
        return truncations
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value)" }
            .joined(separator: ",")
    }
}
