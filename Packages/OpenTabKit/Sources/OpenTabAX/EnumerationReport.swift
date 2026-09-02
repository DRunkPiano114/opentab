import Foundation

/// Result of `AXWindowSource.measure(apps:)`: a cold pass followed by a warm
/// pass over the same apps. Counts and rejections come from the warm pass;
/// `slowestApps` ranks the cold pass, which is where first-contact stalls
/// (Chrome booting its AX bridge, a busy JetBrains IDE) show up. Contains no
/// window titles (L16).
public struct EnumerationReport: Sendable {
    public let coldDuration: Duration
    public let warmDuration: Duration
    public let appsAsked: Int
    /// Elements returned by `kAXWindows` before filtering.
    public let rawWindowCount: Int
    public let keptWindowCount: Int
    public let minimizedCount: Int
    public let rejectedByReason: [String: Int]
    public let subroleDistribution: [String: Int]
    public let slowestApps: [(pid: pid_t, bundleID: String, duration: Duration)]

    public var text: String {
        var lines: [String] = []
        lines.append("AX enumeration: \(appsAsked) apps asked")
        lines.append("  cold \(Self.milliseconds(coldDuration)) ms, warm \(Self.milliseconds(warmDuration)) ms")
        lines.append("  windows: raw \(rawWindowCount), kept \(keptWindowCount), minimized \(minimizedCount)")
        lines.append("  rejected: " + Self.histogram(rejectedByReason))
        lines.append("  subroles: " + Self.histogram(subroleDistribution))
        lines.append("  slowest apps (cold):")
        if slowestApps.isEmpty { lines.append("    (none)") }
        for app in slowestApps {
            let bundle = app.bundleID.isEmpty ? "<no bundle id>" : app.bundleID
            lines.append("    pid \(app.pid) \(bundle) \(Self.milliseconds(app.duration)) ms")
        }
        return lines.joined(separator: "\n")
    }

    static func milliseconds(_ duration: Duration) -> String {
        let components = duration.components
        let ms = Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
        return String(format: "%.1f", ms)
    }

    private static func histogram(_ table: [String: Int]) -> String {
        guard !table.isEmpty else { return "(none)" }
        return table.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }
}
