import ApplicationServices
import Foundation

/// Dumps an application's whole AX tree, bounded on four independent axes so a
/// hostile or wedged app produces a partial file rather than a hang.
enum CommandDump {
    static func run(cli: CLI, output: Output) throws -> Int32 {
        let targets = try resolveTargets(cli: cli)
        guard !targets.isEmpty else {
            throw CLIError("no running application matched '\(cli.positional.first ?? "")'")
        }

        let limits = try cli.walkLimits()
        let renderer = try cli.renderer()
        let getWindow = lookupAXUIElementGetWindow()
        var exitCode: Int32 = 0

        for target in targets {
            let source = AXTreeSource(renderer: renderer, getWindow: getWindow)
            source.dumpAllAttributeValues = cli.flag("values")
            source.includeMenuBar = cli.flag("include-menubar")

            let started = Date()
            let walker = BoundedWalker(source: source, limits: limits, now: started)
            let tree = walker.walk(target.element)
            let elapsed = Date().timeIntervalSince(started)

            let json = JSON.object([
                "command": .string("dump"),
                "target": target.json,
                "axIsProcessTrusted": .bool(AXIsProcessTrusted()),
                "elapsedSeconds": .number(elapsed),
                "walk": walker.statistics,
                "tree": tree,
            ])

            var lines = ["axprobe dump — \(target.name) (\(target.label), pid \(target.pid))", ""]
            lines.append(String(format: "  nodes visited   : %d", walker.nodesVisited))
            lines.append(String(format: "  deepest level   : %d", walker.maxDepthReached))
            lines.append(String(format: "  elapsed         : %.3fs", elapsed))
            lines.append("  complete        : \(walker.isComplete)")
            if !walker.isComplete {
                let reasons = walker.truncations
                    .sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\($0.key.rawValue)=\($0.value)" }
                    .joined(separator: ", ")
                lines.append("  truncated by    : \(reasons)")
            }
            lines.append("")
            lines.append(contentsOf: outline(tree, depth: 0, limit: 40))
            if !AXIsProcessTrusted() {
                lines.append("")
                lines.append("NOT TRUSTED: the tree above is empty because AX is disabled for this process.")
                exitCode = 2
            }

            let name = "dump-" + Output.sanitize(target.bundleIdentifier ?? target.name)
            try output.write(name, json: json, summary: lines.joined(separator: "\n"))
        }
        return exitCode
    }

    static func resolveTargets(cli: CLI) throws -> [Target] {
        if let raw = cli.string("pid") {
            guard let pid = pid_t(raw) else { throw CLIError("--pid must be a number, got '\(raw)'") }
            guard let target = Targets.resolve(pid: pid) else {
                throw CLIError("no running application with pid \(pid)")
            }
            return [target]
        }
        guard let query = cli.positional.first else {
            throw CLIError("expected a bundle id or application name")
        }
        return Targets.resolve(query, exactOnly: cli.flag("exact"))
    }

    /// A short readable slice of the tree for the .txt companion file. The JSON
    /// remains the complete record.
    private static func outline(_ node: JSON, depth: Int, limit: Int) -> [String] {
        var lines: [String] = []
        appendOutline(node, depth: depth, lines: &lines, limit: limit)
        if lines.count >= limit { lines.append("  … full tree in the .json file") }
        return lines
    }

    private static func appendOutline(_ node: JSON, depth: Int, lines: inout [String], limit: Int) {
        guard lines.count < limit, case .object(let fields) = node else { return }
        if case .string(let reason)? = fields["truncated"], fields[kAXRoleAttribute] == nil {
            lines.append(String(repeating: "  ", count: depth + 1) + "<truncated: \(reason)>")
            return
        }
        var label = string(fields[kAXRoleAttribute]) ?? "?"
        if let subrole = string(fields[kAXSubroleAttribute]) { label += "/\(subrole)" }
        if let title = string(fields[kAXTitleAttribute]), !title.isEmpty { label += " '\(title)'" }
        if case .int(let count)? = fields["childCount"], count > 0 { label += " (\(count) children)" }
        if case .string(let reason)? = fields["truncated"] { label += " [truncated: \(reason)]" }
        lines.append(String(repeating: "  ", count: depth + 1) + label)

        if case .array(let children)? = fields["children"] {
            for child in children { appendOutline(child, depth: depth + 1, lines: &lines, limit: limit) }
        }
    }

    private static func string(_ value: JSON?) -> String? {
        if case .string(let string)? = value { return string }
        return nil
    }
}
