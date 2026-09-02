import Foundation

public enum EntryKind: Sendable, Hashable {
    case window
    case tab
}

public struct Entry: Sendable, Identifiable, Hashable {
    public let id: EntryID
    public let kind: EntryKind
    public var key: WindowKey
    public var app: AppInfo
    public var title: String
    public var url: URL?

    public var isMinimized: Bool
    public var isOnActiveSpace: Bool
    public var isHidden: Bool
    /// Always `false` for window entries; P3b writes `TabSnapshot.isPrivate`.
    public var isPrivate: Bool

    /// Monotonic recency counter; primary sort key. Zero means never focused.
    public var focusTick: UInt64
    /// Monotonic, assigned on insertion and never reassigned; stable tie-break.
    public var discoveryRank: UInt64
    /// Always 0 in P0; P3a's store writes it.
    public var missingStrikes: Int

    public init(id: EntryID, kind: EntryKind, key: WindowKey, app: AppInfo, title: String,
                url: URL? = nil, isMinimized: Bool = false, isOnActiveSpace: Bool = true,
                isHidden: Bool = false, isPrivate: Bool = false, focusTick: UInt64 = 0,
                discoveryRank: UInt64, missingStrikes: Int = 0) {
        self.id = id
        self.kind = kind
        self.key = key
        self.app = app
        self.title = title
        self.url = url
        self.isMinimized = isMinimized
        self.isOnActiveSpace = isOnActiveSpace
        self.isHidden = isHidden
        self.isPrivate = isPrivate
        self.focusTick = focusTick
        self.discoveryRank = discoveryRank
        self.missingStrikes = missingStrikes
    }
}
