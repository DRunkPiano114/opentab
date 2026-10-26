import CoreGraphics
import Foundation
import OpenTabCore

/// One app's tab scan, from the windows to read to the snapshots reported.
/// Generic over the tree so the rules that decide what a scan may claim run
/// against a synthetic tree in tests, with no permission and no cooperating
/// app.
struct TabScanEngine<Source: TabTreeSource> {
    struct Input {
        /// `kAXWindows`, in the app's order.
        var axWindows: [Source.Node]
    }

    struct Scan {
        var snapshots: [TabSnapshot] = []
        /// Tab nodes per window, indexed by token.
        var tabs: [CGWindowID: [Source.Node]] = [:]
        var windowsScanned = 0
        var windowsWithoutOneActiveTab = 0
        var windowsUsingDeclaredTabs = 0
        var nodesVisited = 0
        var stops: Set<TabScanStop> = []
        var incomplete = false
    }

    let source: Source
    var limits = TabScanLimits()
    /// The role and subrole filter the window source applies.
    let isListable: (Source.Node) -> Bool
    let windowID: (Source.Node) -> CGWindowID?
    /// `nil` when the WindowServer does not list the window.
    let layer: (CGWindowID) -> Int32?

    func scan(_ input: Input, deadline: ContinuousClock.Instant) throws -> Scan {
        // No window is not the same as no tabs: a full-screen app reports zero
        // AX windows while the window is plainly still there. Saying nothing
        // keeps the rows; saying "empty" would delete them.
        guard !input.axWindows.isEmpty else { throw AXSourceError.cannotComplete }

        var scan = Scan()
        for window in input.axWindows {
            try Self.checkDeadline(deadline)
            guard isListable(window), let id = windowID(window), layer(id) == 0 else { continue }
            read(window, id: id, into: &scan, deadline: deadline)
        }

        // An inconclusive scan must not be reported as "no tabs": that answer
        // is acted on as evidence.
        if scan.snapshots.isEmpty, scan.incomplete { throw AXSourceError.cannotComplete }
        return scan
    }

    private func read(_ window: Source.Node, id: CGWindowID, into scan: inout Scan,
                      deadline: ContinuousClock.Instant) {
        scan.windowsScanned += 1
        let result = TabTreeScanner.scan(window: window, source: source, limits: limits, deadline: deadline)
        scan.nodesVisited += result.nodesVisited
        scan.stops.formUnion(result.stops)
        if result.stops.contains(.deadline) || result.stops.contains(.unreadable)
            || result.stops.contains(.nodes) {
            scan.incomplete = true
        }
        guard !result.tabs.isEmpty else { return }
        if result.usedDeclaredTabs { scan.windowsUsingDeclaredTabs += 1 }

        // Exactly one tab per window carries `AXValue == true`. More than
        // one, or none, means the read caught the strip mid-change; the
        // first selected tab wins and the discrepancy is counted.
        let selected = result.tabs.indices.filter { result.tabs[$0].attributes.isSelected }
        if selected.count != 1 { scan.windowsWithoutOneActiveTab += 1 }
        let active = selected.first

        scan.tabs[id] = result.tabs.map(\.node)
        for (index, tab) in result.tabs.enumerated() {
            scan.snapshots.append(TabSnapshot(windowKey: .cg(id), token: String(index),
                                              title: tab.attributes.displayTitle, url: nil,
                                              isActive: index == active, isPrivate: false))
        }
    }

    static func checkDeadline(_ deadline: ContinuousClock.Instant) throws {
        if ContinuousClock.now >= deadline { throw AXSourceError.deadlineExceeded }
    }
}

extension TabScanEngine.Scan: Sendable where Source.Node: Sendable {}
