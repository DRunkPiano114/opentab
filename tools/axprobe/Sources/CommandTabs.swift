import ApplicationServices
import Foundation

/// The undocumented attribute Chromium and Gecko both implement recursively
/// over a subtree. If it crosses the AX IPC boundary, one read replaces the
/// whole tab-hunting tree walk. That is the question this command answers.
private let axTabsAttribute = "AXTabs"
private let axTabButtonSubrole = "AXTabButton"

private struct ScannedNode {
    let element: AXElement
    let path: [Int]
    let roleChain: [String]
    let role: String
    let subrole: String?
    let title: String?
    let elementDescription: String?
    let identifier: String?
    let value: JSON
    let attributeNames: [String]

    var pathDescription: String {
        "root/" + path.map(String.init).joined(separator: "/")
    }

    var json: JSON {
        .object([
            "path": .string(pathDescription),
            "roleChain": .string(roleChain.joined(separator: " > ")),
            "role": .string(role),
            "subrole": .string(subrole),
            "title": .string(title),
            "description": .string(elementDescription),
            "identifier": .string(identifier),
            "value": value,
        ])
    }
}

/// Bounded, permissive scan of one window.
///
/// The production tab ladder should use a tight descend allow-list; a probe
/// deliberately descends everything except known-huge containers, so that a tab
/// strip hiding somewhere unexpected still shows up.
private final class TabScan {
    private static let neverDescend: Set<String> = [
        "AXWebArea", "AXTable", "AXOutline", "AXList", "AXGrid", "AXTextArea",
        "AXTextField", "AXStaticText", "AXImage", "AXMenu", "AXMenuBar",
        "AXMenuItem", "AXMenuButton", "AXCell", "AXRow", "AXColumn",
    ]

    private let renderer: AXValueRenderer
    private let maxDepth: Int
    private let maxNodes: Int
    private let maxChildren: Int
    private let deadline: Date

    private(set) var nodes: [ScannedNode] = []
    private(set) var stoppedBy: Set<String> = []

    init(renderer: AXValueRenderer, maxDepth: Int, maxNodes: Int, maxChildren: Int, budget: TimeInterval) {
        self.renderer = renderer
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.maxChildren = maxChildren
        self.deadline = Date().addingTimeInterval(budget)
    }

    func scan(root: AXElement) {
        var stack: [(element: AXElement, path: [Int], chain: [String], depth: Int)] = []
        guard let rootNode = describe(root, path: [], chain: []) else { return }
        nodes.append(rootNode)
        stack.append((root, [], [rootNode.role], 0))

        while let frame = stack.popLast() {
            if Date() >= deadline { stoppedBy.insert("deadline"); return }
            if nodes.count >= maxNodes { stoppedBy.insert("budget"); return }
            if frame.depth >= maxDepth { stoppedBy.insert("depth"); continue }

            let parentRole = frame.chain.last ?? ""
            if Self.neverDescend.contains(parentRole) { continue }

            let total = AXRead.count(frame.element, kAXChildrenAttribute).count
            if total > maxChildren { stoppedBy.insert("children") }
            let children = AXRead.children(frame.element, limit: min(total, maxChildren))

            for (index, child) in children.enumerated() {
                guard nodes.count < maxNodes else { stoppedBy.insert("budget"); return }
                let path = frame.path + [index]
                guard let node = describe(child, path: path, chain: frame.chain) else { continue }
                nodes.append(node)
                stack.append((child, path, frame.chain + [node.role], frame.depth + 1))
            }
        }
    }

    private func describe(_ element: AXElement, path: [Int], chain: [String]) -> ScannedNode? {
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
                          kAXDescriptionAttribute, kAXIdentifierAttribute, kAXValueAttribute]
        guard let values = AXRead.multiple(element, attributes),
              let role = values[0] as? String else { return nil }
        let names = AXRead.attributeNames(element).names
        return ScannedNode(
            element: element, path: path, roleChain: chain + [role], role: role,
            subrole: values[1] as? String, title: values[2] as? String,
            elementDescription: values[3] as? String, identifier: values[4] as? String,
            value: renderer.render(values[5]), attributeNames: names)
    }
}

private struct StrategyReport {
    let id: String
    let explanation: String
    var advertised: Bool?
    var status: String
    var error: String?
    var hits: [JSON] = []
    var note: String?

    var json: JSON {
        var fields: [String: JSON] = [
            "id": .string(id),
            "explanation": .string(explanation),
            "status": .string(status),
            "hitCount": .int(hits.count),
            "hits": .array(hits),
        ]
        if let advertised { fields["attributeAdvertised"] = .bool(advertised) }
        if let error { fields["error"] = .string(error) }
        if let note { fields["note"] = .string(note) }
        return .object(fields)
    }
}

enum CommandTabs {
    static func run(cli: CLI, output: Output) throws -> Int32 {
        let targets = try CommandDump.resolveTargets(cli: cli)
        guard let target = targets.first else {
            throw CLIError("no running application matched '\(cli.positional.first ?? "")'")
        }
        let ambiguous = targets.count > 1
            ? targets.map { "\($0.label) (pid \($0.pid))" }
            : []

        let renderer = try cli.renderer()
        let limits = try cli.walkLimits()
        let application = target.element
        let (windows, windowsError) = AXRead.elements(application, kAXWindowsAttribute)

        var reports: [StrategyReport] = []
        reports.append(directTabs(on: application, label: "application", path: "root",
                                  id: "S1 app.AXTabs",
                                  explanation: "Read AXTabs directly on the application element.",
                                  renderer: renderer))

        var windowSummaries: [JSON] = []
        var scans: [(index: Int, window: AXElement, scan: TabScan)] = []

        for (index, window) in windows.enumerated() {
            let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute]
            let values = AXRead.multiple(window, attributes)
            windowSummaries.append(.object([
                "index": .int(index),
                "role": .string(values?[0] as? String),
                "subrole": .string(values?[1] as? String),
                "title": .string(values?[2] as? String),
            ]))

            reports.append(directTabs(on: window, label: "window[\(index)]", path: "root/window[\(index)]",
                                      id: "S2 window[\(index)].AXTabs",
                                      explanation: "Read AXTabs directly on a window element.",
                                      renderer: renderer))

            let scan = TabScan(renderer: renderer,
                               maxDepth: min(limits.maxDepth, 10),
                               maxNodes: min(limits.maxNodes, 600),
                               maxChildren: limits.maxChildren,
                               budget: limits.budget)
            scan.scan(root: window)
            scans.append((index, window, scan))
        }

        reports.append(nativeTabGroups(scans: scans))
        reports.append(tabGroupTabs(scans: scans, renderer: renderer))
        reports.append(tabButtonSweep(scans: scans))
        reports.append(tabAttributeSweep(application: application, scans: scans))

        let trusted = AXIsProcessTrusted()
        let json = JSON.object([
            "command": .string("tabs"),
            "target": target.json,
            "axIsProcessTrusted": .bool(trusted),
            "windowsError": .string(axErrorName(windowsError)),
            "ambiguousMatches": .strings(ambiguous),
            "windows": .array(windowSummaries),
            "scan": .object([
                "nodesPerWindow": .array(scans.map { .int($0.scan.nodes.count) }),
                "stoppedBy": .strings(scans.flatMap { Array($0.scan.stoppedBy) }.uniqued().sorted()),
            ]),
            "strategies": .array(reports.map(\.json)),
            "verdict": verdict(reports: reports),
        ])

        var lines = ["axprobe tabs — \(target.name) (\(target.label), pid \(target.pid))", ""]
        if !ambiguous.isEmpty {
            lines.append("  WARNING: \(targets.count) processes matched; probed the first.")
            lines.append("           matches: \(ambiguous.joined(separator: ", "))")
        }
        lines.append("  windows: \(windows.count) (\(axErrorName(windowsError)))")
        lines.append("  scanned nodes: \(scans.map { $0.scan.nodes.count }.reduce(0, +))")
        lines.append("")
        for report in reports {
            let advertised = report.advertised.map { $0 ? " advertised" : " not-advertised" } ?? ""
            lines.append("  [\(report.status.uppercased())] \(report.id)\(advertised) — \(report.hits.count) hit(s)")
            if let error = report.error { lines.append("        error: \(error)") }
            for hit in report.hits.prefix(12) { lines.append("        " + describeHit(hit)) }
            if report.hits.count > 12 { lines.append("        … \(report.hits.count - 12) more in the .json") }
        }
        lines.append("")
        if case .object(let fields) = verdict(reports: reports),
           case .string(let text)? = fields["summary"] {
            lines.append("  VERDICT: \(text)")
        }
        if !trusted {
            lines.append("")
            lines.append("NOT TRUSTED: no strategy could run. Run `make doctor` for the grant steps.")
        }

        let name = "tabs-" + Output.sanitize(target.bundleIdentifier ?? target.name)
        try output.write(name, json: json, summary: lines.joined(separator: "\n"))
        return trusted ? 0 : 2
    }

    private static func directTabs(on element: AXElement, label: String, path: String,
                                   id: String, explanation: String,
                                   renderer: AXValueRenderer) -> StrategyReport {
        let advertised = AXRead.attributeNames(element).names.contains(axTabsAttribute)
        let (elements, error) = AXRead.elements(element, axTabsAttribute)

        var report = StrategyReport(id: id, explanation: explanation,
                                    advertised: advertised, status: "miss")
        switch error {
        case .success where !elements.isEmpty:
            report.status = "hit"
            report.hits = elements.enumerated().map { index, tab in
                describeElement(tab, path: "\(path).AXTabs[\(index)]", renderer: renderer)
            }
        case .success:
            report.status = "empty"
            report.note = "AXTabs is implemented on \(label) but returned no elements."
        case .attributeUnsupported:
            report.status = "unsupported"
            report.error = axErrorName(error)
        case .noValue:
            report.status = "empty"
            report.error = axErrorName(error)
        default:
            report.status = "error"
            report.error = axErrorName(error)
        }
        if advertised && report.status == "unsupported" {
            report.note = "attribute is advertised but reads as unsupported"
        }
        if !advertised && report.status == "hit" {
            report.note = "attribute works despite not being advertised in AXUIElementCopyAttributeNames"
        }
        return report
    }

    /// The alt-tab-macos algorithm: window -> depth-1 AXTabGroup -> AXTabButton
    /// children. Three calls, no tree walk. The >= 2 test rejects Safari, which
    /// exposes an AXTabGroup with zero tab buttons.
    private static func nativeTabGroups(scans: [(index: Int, window: AXElement, scan: TabScan)]) -> StrategyReport {
        var report = StrategyReport(
            id: "S3 window > AXTabGroup(depth 1) > AXTabButton",
            explanation: "alt-tab-macos native path: the tab group is a direct child of the window.",
            status: "miss")
        for entry in scans {
            let groups = entry.scan.nodes.filter { $0.role == kAXTabGroupRole && $0.path.count == 1 }
            for group in groups {
                let buttons = entry.scan.nodes.filter {
                    $0.subrole == axTabButtonSubrole && $0.path.count == 2
                        && Array($0.path.prefix(1)) == group.path
                }
                report.hits.append(.object([
                    "window": .int(entry.index),
                    "tabGroupPath": .string(group.pathDescription),
                    "tabButtonCount": .int(buttons.count),
                    "passesTwoTabTest": .bool(buttons.count >= 2),
                    "tabs": .array(buttons.map(\.json)),
                ]))
            }
        }
        report.status = report.hits.isEmpty ? "miss" : "hit"
        return report
    }

    private static func tabGroupTabs(scans: [(index: Int, window: AXElement, scan: TabScan)],
                                     renderer: AXValueRenderer) -> StrategyReport {
        var report = StrategyReport(
            id: "S4 AXTabGroup.AXTabs",
            explanation: "Read AXTabs on every AXTabGroup found anywhere in the scan.",
            status: "miss")
        var anyAdvertised = false
        for entry in scans {
            for group in entry.scan.nodes where group.role == kAXTabGroupRole {
                if group.attributeNames.contains(axTabsAttribute) { anyAdvertised = true }
                let (elements, error) = AXRead.elements(group.element, axTabsAttribute)
                guard error == .success, !elements.isEmpty else {
                    if error != .attributeUnsupported && error != .noValue && error != .success {
                        report.error = axErrorName(error)
                    }
                    continue
                }
                report.hits.append(.object([
                    "window": .int(entry.index),
                    "tabGroupPath": .string(group.pathDescription),
                    "tabCount": .int(elements.count),
                    "tabs": .array(elements.enumerated().map { index, tab in
                        describeElement(tab, path: "\(group.pathDescription).AXTabs[\(index)]",
                                        renderer: renderer)
                    }),
                ]))
            }
        }
        report.advertised = anyAdvertised
        report.status = report.hits.isEmpty ? "miss" : "hit"
        return report
    }

    /// The structural predicate that covers native AppKit and Chromium alike.
    private static func tabButtonSweep(scans: [(index: Int, window: AXElement, scan: TabScan)]) -> StrategyReport {
        var report = StrategyReport(
            id: "S5 bounded DFS for AXSubrole == AXTabButton",
            explanation: "Depth/budget-bounded search of the whole window subtree.",
            status: "miss")
        for entry in scans {
            for node in entry.scan.nodes where node.subrole == axTabButtonSubrole {
                var fields: [String: JSON] = ["window": .int(entry.index)]
                if case .object(let base) = node.json { fields.merge(base) { _, new in new } }
                report.hits.append(.object(fields))
            }
        }
        report.status = report.hits.isEmpty ? "miss" : "hit"
        return report
    }

    /// Catches non-standard attributes an app may use for its tab strip.
    private static func tabAttributeSweep(application: AXElement,
                                          scans: [(index: Int, window: AXElement, scan: TabScan)]) -> StrategyReport {
        var report = StrategyReport(
            id: "S6 attribute-name sweep for /tab/i",
            explanation: "Every attribute name containing 'tab' seen anywhere, with the element that exposes it.",
            status: "miss")
        var seen: Set<String> = []

        func record(_ names: [String], path: String, role: String) {
            for name in names where name.lowercased().contains("tab") {
                let key = "\(role)|\(name)"
                guard seen.insert(key).inserted else { continue }
                report.hits.append(.object([
                    "attribute": .string(name), "role": .string(role), "path": .string(path),
                ]))
            }
        }

        record(AXRead.attributeNames(application).names, path: "root", role: "AXApplication")
        for entry in scans {
            for node in entry.scan.nodes {
                record(node.attributeNames, path: node.pathDescription, role: node.role)
            }
        }
        report.status = report.hits.isEmpty ? "miss" : "hit"
        return report
    }

    /// Answers the open question directly rather than leaving it to the reader.
    private static func verdict(reports: [StrategyReport]) -> JSON {
        let tabsHits = reports.filter { $0.id.contains("AXTabs") && $0.status == "hit" }
        let walkHits = reports.filter { ($0.id.contains("S3") || $0.id.contains("S5")) && $0.status == "hit" }
        let tabsCount = tabsHits.map(\.hits.count).reduce(0, +)

        let summary: String
        if !tabsHits.isEmpty && !walkHits.isEmpty {
            summary = "AXTabs works AND the tree walk works — compare counts before dropping the walk."
        } else if !tabsHits.isEmpty {
            summary = "AXTabs works and the tree walk found nothing: one read replaces the walk for this app."
        } else if !walkHits.isEmpty {
            summary = "AXTabs did not work; only the tree walk found tabs for this app."
        } else {
            summary = "No strategy found tabs for this app."
        }

        return .object([
            "summary": .string(summary),
            "axTabsStrategiesThatWorked": .strings(tabsHits.map(\.id)),
            "axTabsElementCount": .int(tabsCount),
            "treeWalkStrategiesThatWorked": .strings(walkHits.map(\.id)),
        ])
    }

    private static func describeElement(_ element: AXElement, path: String,
                                        renderer: AXValueRenderer) -> JSON {
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
                          kAXDescriptionAttribute, kAXIdentifierAttribute, kAXValueAttribute]
        let values = AXRead.multiple(element, attributes)
        return .object([
            "path": .string(path),
            "role": .string(values?[0] as? String),
            "subrole": .string(values?[1] as? String),
            "title": .string(values?[2] as? String),
            "description": .string(values?[3] as? String),
            "identifier": .string(values?[4] as? String),
            "value": renderer.render(values?[5] ?? nil),
        ])
    }

    private static func describeHit(_ hit: JSON) -> String {
        guard case .object(let fields) = hit else { return "-" }
        func text(_ key: String) -> String? {
            if case .string(let value)? = fields[key] { return value }
            if case .int(let value)? = fields[key] { return String(value) }
            return nil
        }
        if let attribute = text("attribute") {
            return "\(attribute) on \(text("role") ?? "?") at \(text("path") ?? "?")"
        }
        if let group = text("tabGroupPath") {
            let count = text("tabButtonCount") ?? text("tabCount") ?? "?"
            return "\(group) -> \(count) tab(s)"
        }
        let role = text("role") ?? "?"
        let subrole = text("subrole").map { "/\($0)" } ?? ""
        let title = text("title").map { " '\($0)'" } ?? ""
        return "\(text("path") ?? "?")  \(role)\(subrole)\(title)"
    }
}

extension Array where Element: Hashable {
    fileprivate func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
