import Foundation

public enum SortMode: Sendable {
    case recency
    case alphabetical
}

public enum EntrySort {
    /// Recency: `focusTick` descending, `discoveryRank` ascending as the
    /// tie-break. Alphabetical: `(app.localizedName, title)`, same tie-break.
    /// The tie-break is what stops rows discovered in the same pass from
    /// swapping places between renders.
    public static func sorted(_ entries: [Entry], mode: SortMode) -> [Entry] {
        switch mode {
        case .recency:
            return entries.sorted { a, b in
                if a.focusTick != b.focusTick { return a.focusTick > b.focusTick }
                return a.discoveryRank < b.discoveryRank
            }
        case .alphabetical:
            return entries.sorted { a, b in
                let byApp = a.app.localizedName.localizedCaseInsensitiveCompare(b.app.localizedName)
                if byApp != .orderedSame { return byApp == .orderedAscending }
                let byTitle = a.title.localizedCaseInsensitiveCompare(b.title)
                if byTitle != .orderedSame { return byTitle == .orderedAscending }
                return a.discoveryRank < b.discoveryRank
            }
        }
    }
}

/// Precomputed group sizes; never derive these during rendering.
public struct GroupCounts: Sendable, Equatable {
    public let byWindowKey: [WindowKey: Int]
    public let byAppKey: [AppKey: Int]

    public init<S: Sequence>(entries: S) where S.Element == Entry {
        var windows: [WindowKey: Int] = [:]
        var apps: [AppKey: Int] = [:]
        for entry in entries {
            windows[entry.key, default: 0] += 1
            apps[entry.app.key, default: 0] += 1
        }
        byWindowKey = windows
        byAppKey = apps
    }

    /// The number shown in the row's count column, or `nil` when the group has
    /// a single member (the count is omitted then).
    public func displayCount(forApp key: AppKey) -> Int? {
        guard let count = byAppKey[key], count > 1 else { return nil }
        return count
    }
}
