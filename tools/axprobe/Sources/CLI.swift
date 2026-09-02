import Foundation

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Hand-rolled argument parsing. The tool is launched through LaunchServices
/// (`open -n -a AXProbe.app --args …`), which can append its own `-psn_…`
/// argument, so unknown-looking arguments have to be handled deliberately
/// rather than by a general-purpose parser.
struct CLI {
    let command: String
    let positional: [String]
    private let values: [String: String]
    private let switches: Set<String>

    static let valueOptions: Set<String> = [
        "out", "max-depth", "max-nodes", "max-children", "budget", "timeout",
        "max-string", "pid", "wid", "max-id",
    ]
    static let switchOptions: Set<String> = [
        "values", "include-menubar", "help", "exact",
    ]

    init(arguments: [String]) throws {
        var remaining = arguments.filter { !$0.hasPrefix("-psn_") }
        guard !remaining.isEmpty else {
            throw CLIError("no command given")
        }
        command = remaining.removeFirst()

        var positional: [String] = []
        var values: [String: String] = [:]
        var switches: Set<String> = []

        var index = 0
        while index < remaining.count {
            let argument = remaining[index]
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                if Self.valueOptions.contains(name) {
                    guard index + 1 < remaining.count else {
                        throw CLIError("--\(name) requires a value")
                    }
                    values[name] = remaining[index + 1]
                    index += 2
                    continue
                }
                if Self.switchOptions.contains(name) {
                    switches.insert(name)
                    index += 1
                    continue
                }
                throw CLIError("unknown option --\(name)")
            }
            positional.append(argument)
            index += 1
        }

        self.positional = positional
        self.values = values
        self.switches = switches
    }

    func flag(_ name: String) -> Bool { switches.contains(name) }

    func string(_ name: String) -> String? { values[name] }

    func int(_ name: String, default fallback: Int) throws -> Int {
        guard let raw = values[name] else { return fallback }
        guard let parsed = Int(raw), parsed > 0 else {
            throw CLIError("--\(name) must be a positive integer, got '\(raw)'")
        }
        return parsed
    }

    func double(_ name: String, default fallback: Double) throws -> Double {
        guard let raw = values[name] else { return fallback }
        guard let parsed = Double(raw), parsed > 0 else {
            throw CLIError("--\(name) must be a positive number, got '\(raw)'")
        }
        return parsed
    }

    func walkLimits() throws -> WalkLimits {
        var limits = WalkLimits()
        limits.maxDepth = min(try int("max-depth", default: 12), 64)
        limits.maxNodes = try int("max-nodes", default: 4000)
        limits.maxChildren = try int("max-children", default: 100)
        limits.budget = try double("budget", default: 20)
        return limits
    }

    func renderer() throws -> AXValueRenderer {
        var renderer = AXValueRenderer()
        renderer.maxStringLength = try int("max-string", default: 200)
        return renderer
    }

    static let usage = """
    axprobe \(AXProbe.version) — Accessibility tree probe for OpenTab

    USAGE
      axprobe <command> [target] [options]

    COMMANDS
      doctor                 Report trust state, bundle identity and designated requirement.
      list                   List running apps: pid, bundle id, name, window counts.
      dump <bundle-id|name>  Dump the full AX tree of an app to JSON.
      tabs <bundle-id|name>  Try every tab-location strategy and report which worked.
      spaces                 Compare AX-reachable windows against the WindowServer list.
      token                  Strategy C: reach off-Space/fullscreen windows via remote token.
      spacemap               CGS Space attribution: which Space each window and display is on.
      selftest               Verify the walker's depth/breadth/budget/deadline caps.

    OPTIONS
      --out <dir>            Output directory (default: ~/Library/Application Support/\(AXProbe.bundleIdentifierFallback)).
      --timeout <seconds>    Global AX messaging timeout (default: 0.25).
      --max-depth <n>        Tree depth cap, hard limit 64 (default: 12).
      --max-nodes <n>        Total node budget (default: 4000).
      --max-children <n>     Children read per node (default: 100).
      --budget <seconds>     Wall-clock walk budget (default: 20).
      --max-string <n>       Truncate string attribute values (default: 200).
      --values               Also dump every advertised attribute's value.
      --include-menubar      Descend into AXMenuBar (large and usually noise).
      --exact                Match the bundle id or name exactly; never fall back
                             to a substring match (batch runs want this, so that
                             "com.apple.Safari" cannot resolve to a Safari helper).
      --pid <pid>            For dump/tabs/token: target this pid instead of matching a name.
      --wid <id[,id…]>       For token/spacemap: CGWindowID(s) to reach or attribute.
      --max-id <n>           token: highest AXUIElementID to sweep (default: 32768).

    This tool is read-only: it never performs an AX action and never sets an
    attribute. It must be launched with `open -a` so that it gets its own TCC
    identity; running the binary from a shell inherits the terminal's grant and
    reports a false positive.
    """
}
