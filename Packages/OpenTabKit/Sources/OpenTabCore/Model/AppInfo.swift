import Foundation

public struct AppInfo: Sendable, Hashable {
    /// Empty when the process has no bundle identifier.
    public let bundleID: String
    public let pid: pid_t
    /// Display only. Never branch on it: it is localised.
    public let localizedName: String

    public init(bundleID: String, pid: pid_t, localizedName: String) {
        self.bundleID = bundleID
        self.pid = pid
        self.localizedName = localizedName
    }

    public var key: AppKey {
        bundleID.isEmpty ? .pid(pid) : .bundle(bundleID)
    }
}
