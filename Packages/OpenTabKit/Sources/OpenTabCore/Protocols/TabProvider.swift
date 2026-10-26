import Foundation

public protocol TabProvider: Sendable {
    var bundleIDs: [String] { get }
    /// Chromium tokens are stable ids; Safari tokens are positional indices.
    var tokenStability: TokenStability { get }
    func readTabs(for app: AppInfo, deadline: ContinuousClock.Instant) async throws -> [TabSnapshot]
    /// `readTabs` with the windows the answer speaks for.
    func readTabsWithCoverage(for app: AppInfo, deadline: ContinuousClock.Instant) async throws -> TabRead
    func activate(_ tab: TabSnapshot, deadline: ContinuousClock.Instant) async throws
}

/// One tab read and the windows it speaks for, keyed as its snapshots are.
public struct TabRead: Sendable {
    public var snapshots: [TabSnapshot]
    public var coverage: TabCoverage

    public init(snapshots: [TabSnapshot], coverage: TabCoverage) {
        self.snapshots = snapshots
        self.coverage = coverage
    }
}

extension TabProvider {
    /// A provider that lists every window of the app in one call speaks for
    /// all of them.
    public func readTabsWithCoverage(for app: AppInfo, deadline: ContinuousClock.Instant) async throws -> TabRead {
        TabRead(snapshots: try await readTabs(for: app, deadline: deadline), coverage: .complete)
    }
}
