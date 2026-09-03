import AppKit
import OpenTabCore

/// `AppDirectory` over `NSWorkspace`. Our own pid is excluded (L9), the
/// ignore list is matched by bundle id only (L3), and only processes that own
/// a layer-0 window in the window server are candidates (L4 allows CG as an
/// existence check; it is never the window list).
public final class WorkspaceAppDirectory: AppDirectory, Sendable {
    private let ignoreRules: IgnoreRules
    private let cgTable = CGWindowTable()

    public init(ignoreRules: IgnoreRules = IgnoreRules()) {
        self.ignoreRules = ignoreRules
    }

    @MainActor
    public func runningApps() -> [AppInfo] {
        let mine = getpid()
        let owners = cgTable.layerZeroOwnerPIDs()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, app.processIdentifier != mine,
                  owners.contains(app.processIdentifier),
                  app.activationPolicy == .regular || app.activationPolicy == .accessory
            else { return nil }
            let bundleID = app.bundleIdentifier ?? ""
            guard !ignoreRules.bundleIDs.contains(bundleID) else { return nil }
            return AppInfo(bundleID: bundleID, pid: app.processIdentifier,
                           localizedName: app.localizedName ?? "")
        }
    }

    @MainActor
    public func isHidden(_ app: AppInfo) -> Bool {
        NSRunningApplication(processIdentifier: app.pid)?.isHidden ?? false
    }
}
