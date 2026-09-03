import Foundation

public protocol WindowSource: Sendable {
    /// Every window of one app. A read that overruns `deadline` throws; it never
    /// returns a partial list as success (L5).
    func snapshot(of app: AppInfo, deadline: ContinuousClock.Instant) async throws -> [WindowSnapshot]
}

public protocol WindowActivator: Sendable {
    /// Success is judged by reading the target app's `kAXFrontmostAttribute`
    /// back, never by an AppKit return value (L2).
    func activate(_ key: WindowKey, deadline: ContinuousClock.Instant) async throws
}

/// The running processes worth asking for windows. Implemented over
/// `NSWorkspace` in the app; faked in tests.
public protocol AppDirectory: Sendable {
    @MainActor func runningApps() -> [AppInfo]
    /// `NSRunningApplication.isHidden`. Unreliable per L2: a secondary sort
    /// signal and an input to the activation path, never a reason to hide rows.
    @MainActor func isHidden(_ app: AppInfo) -> Bool
    /// `NSWorkspace.frontmostApplication`, if it is a candidate.
    @MainActor func frontmostApp() -> AppInfo?
}
