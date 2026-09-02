import AppKit
import OpenTabCore

/// `AppDirectory` over `NSWorkspace`. Our own pid is excluded (L9) and the
/// ignore list is matched by bundle id only (L3).
public final class WorkspaceAppDirectory: AppDirectory, Sendable {
    private let ignoreRules: IgnoreRules

    public init(ignoreRules: IgnoreRules = IgnoreRules()) {
        self.ignoreRules = ignoreRules
    }

    @MainActor
    public func runningApps() -> [AppInfo] {
        let mine = getpid()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, app.processIdentifier != mine,
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
