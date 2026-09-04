import AppKit

/// `tell application` launches a target that is not running, so every send
/// is gated on this first.
public protocol BrowserLiveness: Sendable {
    func isRunning(bundleID: String) -> Bool
}

public struct WorkspaceBrowserLiveness: BrowserLiveness {
    public init() {}

    public func isRunning(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { !$0.isTerminated }
    }
}
