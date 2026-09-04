import Foundation

/// Raw result of one window read. Produced by a `WindowSource`.
public struct WindowSnapshot: Sendable, Hashable {
    public let key: WindowKey
    public let app: AppInfo
    /// Display only. Read as `title.isEmpty ? description : title`.
    public let title: String
    /// Raw `AXSubrole` value, not localised.
    public let subrole: String
    /// From `kAXMinimizedAttribute`, never inferred from the subrole.
    public let isMinimized: Bool
    /// Always `true` for the pure-AX source: it only sees the current Space.
    /// The off-space source fills it from CGS Space membership.
    public let isOnActiveSpace: Bool
    /// CoreGraphics window layer, known only for `.cg` keys.
    public let level: Int32?
    /// Whether this window is the app's focused window (`kAXFocusedWindowAttribute`).
    /// Drives `Entry.focusTick` when the app is activated.
    public let isFocused: Bool

    public init(key: WindowKey, app: AppInfo, title: String, subrole: String,
                isMinimized: Bool, isOnActiveSpace: Bool = true, level: Int32? = nil,
                isFocused: Bool = false) {
        self.key = key
        self.app = app
        self.title = title
        self.subrole = subrole
        self.isMinimized = isMinimized
        self.isOnActiveSpace = isOnActiveSpace
        self.level = level
        self.isFocused = isFocused
    }
}

/// Raw result of one tab read. Produced by a `TabProvider`.
public struct TabSnapshot: Sendable, Hashable {
    public let windowKey: WindowKey
    /// Stable within the provider's domain; see `TokenStability`.
    public let token: String
    public let title: String
    public let url: URL?
    public let isActive: Bool
    public let isPrivate: Bool
    /// The provider identified a private window and withheld its tabs.
    /// One such snapshot stands for the whole window: it names no tab, and its
    /// `title` is the window's own, carried only so the reconciler can find the
    /// Accessibility row that shows the same window and suppress it. The
    /// reconciler never turns it into an entry and never stores its title.
    public let withholdsTabs: Bool

    public init(windowKey: WindowKey, token: String, title: String, url: URL?,
                isActive: Bool, isPrivate: Bool, withholdsTabs: Bool = false) {
        self.windowKey = windowKey
        self.token = token
        self.title = title
        self.url = url
        self.isActive = isActive
        self.isPrivate = isPrivate
        self.withholdsTabs = withholdsTabs
    }
}
