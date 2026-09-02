import Foundation

public protocol TabProvider: Sendable {
    var bundleIDs: [String] { get }
    /// Chromium tokens are stable ids; Safari tokens are positional indices.
    var tokenStability: TokenStability { get }
    func readTabs(for app: AppInfo, deadline: ContinuousClock.Instant) async throws -> [TabSnapshot]
    func activate(_ tab: TabSnapshot, deadline: ContinuousClock.Instant) async throws
}

/// Empty shell; P1 fills it in.
public protocol SearchIndex: Sendable {}
