import CoreGraphics
import Foundation
import OpenTabAX
import OpenTabCore

/// Diagnostics for the off-space path: which private symbols resolved, the
/// scan configuration, the Space topology, whether `CGSGetWindowLevel` agrees
/// with the public window layer, and per-app reach counts. Counts only,
/// never titles (L16).
public enum OffSpaceDiagnostics {
    /// CGS Space ids of a window; `nil` when the CGS symbols are missing.
    public static func spaceIDs(of windowID: CGWindowID) -> [UInt64]? {
        SpaceMap()?.spaces(of: windowID)
    }

    public static func symbolTable() -> [String] {
        WSPrivateSymbols.availabilityTable.map { "  \($0.resolved ? "ok     " : "MISSING") \($0.name)" }
    }

    /// `CGSGetWindowLevel` against `kCGWindowLayer` for up to `sample` rows.
    /// Returns the verdict plus how many rows agreed.
    public static func verifyWindowLevel(sample: Int = 20) -> (verdict: String, agreed: Int, compared: Int) {
        guard let getLevel = WSPrivateSymbols.getWindowLevel,
              let connection = WSPrivateSymbols.mainConnectionID?() else {
            return ("unavailable", 0, 0)
        }
        let info = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                    as? [[String: Any]]) ?? []
        var agreed = 0
        var compared = 0
        for entry in info.prefix(sample) {
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  let layer = entry[kCGWindowLayer as String] as? Int else { continue }
            var level: Int32 = 0
            guard getLevel(connection, CGWindowID(number), &level) == 0 else { continue }
            compared += 1
            if Int(level) == layer { agreed += 1 }
        }
        let verdict = compared == 0 ? "no rows" : (agreed == compared ? "agrees with kCGWindowLayer" : "DISAGREES")
        return (verdict, agreed, compared)
    }

    public static func report(source: OffSpaceWindowSource, apps: [AppInfo]) async -> String {
        var lines = ["off-space diagnostics"]
        lines.append("symbols:")
        lines.append(contentsOf: symbolTable())
        let availability = source.availability
        lines.append("tokenPath=\(availability.tokenPath) spaceMap=\(availability.spaceMap) active=\(source.isTokenPathActive) windowIDBridge=\(source.base.isWindowIDBridgeAvailable)")
        let configuration = source.configuration
        lines.append("scan maxElementID=\(configuration.maxElementID) budget=\(configuration.scanBudget) exhaustedRetry=\(configuration.exhaustedRetry)")
        let level = verifyWindowLevel()
        lines.append("CGSGetWindowLevel: \(level.verdict) (\(level.agreed)/\(level.compared))")

        if let spaceMap = SpaceMap() {
            for display in spaceMap.displays() {
                lines.append("display \(display.identifier): current=\(display.currentSpace.map(String.init) ?? "?") spaces=\(display.spaces)")
            }
            lines.append("activeSpaces=\(spaceMap.activeSpaces().sorted())")
        }

        lines.append("per app (bundle ax cg0 candidates token kept unreached exhausted probed filtered noSpace orderedOut onActive/total):")
        for app in apps.sorted(by: { $0.bundleID < $1.bundleID }) {
            let deadline = ContinuousClock.now + .seconds(1)
            guard let snapshots = try? await source.snapshot(of: app, deadline: deadline) else {
                lines.append("  \(label(app)) readFailed")
                continue
            }
            guard let report = source.report(for: app.pid) else {
                lines.append("  \(label(app)) \(snapshots.count) (no augmentation)")
                continue
            }
            let onActive = snapshots.filter(\.isOnActiveSpace).count
            lines.append("  \(label(app)) \(report.axWindows) \(report.layerZeroRows) \(report.candidates) \(report.reachedViaToken) \(report.keptUnreached) \(report.unreached) \(report.exhausted) \(report.probed) \(report.filtered) \(report.noSpace) \(report.orderedOut) \(onActive)/\(snapshots.count)")
        }

        let hits = source.hitElementIDs().filter { !$0.elementIDs.isEmpty }
        lines.append("token hits (pid bundle count min max):")
        if hits.isEmpty { lines.append("  (none)") }
        for hit in hits {
            lines.append("  \(hit.pid) \(hit.bundleID.isEmpty ? "-" : hit.bundleID) \(hit.elementIDs.count) \(hit.elementIDs.min()!) \(hit.elementIDs.max()!)")
        }
        return lines.joined(separator: "\n")
    }

    /// E0's cross-check on every running app: ignore what AX enumerates and
    /// reach each window through the token scan alone, with a budget wide
    /// enough for one full cycle. Reports how many of the AX-listed windows
    /// the scan reproduced and where their element ids sit (H18).
    public static func tokenCrossCheck(base: AXWindowSource, apps: [AppInfo]) async -> String {
        var configuration = OffSpaceConfiguration()
        configuration.scanBudget = .seconds(3)
        let source = OffSpaceWindowSource(base: base, configuration: configuration)
        guard source.isTokenPathActive else { return "token cross-check skipped: token path inactive" }
        var lines = ["token cross-check (bundle axWindows tokenReached probed exhausted noSpace ms elementIDs):"]
        for app in apps.sorted(by: { $0.bundleID < $1.bundleID }) {
            let started = ContinuousClock.now
            guard let viaAX = try? await base.snapshot(of: app, deadline: .now + .seconds(1)) else {
                lines.append("  \(label(app)) readFailed")
                continue
            }
            let axIDs = Set(viaAX.compactMap { snapshot -> CGWindowID? in
                if case .cg(let id) = snapshot.key { return id }
                return nil
            })
            guard let viaToken = try? await source.snapshotViaTokenOnly(of: app, deadline: .now + .seconds(4)),
                  let report = source.report(for: app.pid) else {
                lines.append("  \(label(app)) \(viaAX.count) scanFailed")
                continue
            }
            let reproduced = viaToken.filter { snapshot in
                if case .cg(let id) = snapshot.key { return axIDs.contains(id) }
                return false
            }.count
            let ids = source.hitElementIDs().first { $0.pid == app.pid }?.elementIDs ?? []
            let ms = milliseconds(started.duration(to: .now))
            lines.append("  \(label(app)) \(viaAX.count) \(reproduced) \(report.probed) \(report.exhausted) \(report.noSpace) \(ms) \(ids.sorted())")
        }
        return lines.joined(separator: "\n")
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let parts = duration.components
        return String(format: "%.0f", Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15)
    }

    private static func label(_ app: AppInfo) -> String {
        app.bundleID.isEmpty ? "pid\(app.pid)" : app.bundleID
    }
}
