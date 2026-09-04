import Foundation

/// Two identity spaces coexist: the Accessibility side and the AppleScript side
/// name the same window differently. `TabStore` reconciles them.
public enum WindowKey: Hashable, Sendable {
    /// The underlying type of `CGWindowID`; this module has no CoreGraphics dependency.
    case cg(UInt32)
    /// Fallback when `_AXUIElementGetWindow` is unavailable or fails for a
    /// window. `WindowResolver` upgrades these to `.cg` when the bridge or
    /// the frame fallback can name the window.
    case ax(pid: pid_t, elementID: UInt64)
    /// Produced by AppleScript providers.
    case scripted(bundleID: String, token: String)
}

/// Stable identity of a list entry across refreshes; the UI diffs on it.
public struct EntryID: Hashable, Sendable {
    public let key: WindowKey
    /// `nil` marks a window entry.
    public let tabToken: String?

    public init(key: WindowKey, tabToken: String? = nil) {
        self.key = key
        self.tabToken = tabToken
    }

    public static func window(_ key: WindowKey) -> EntryID { EntryID(key: key) }
}

/// Bundle id first, pid as fallback for processes without one. Group counts and
/// per-app serialisation key on this.
public enum AppKey: Hashable, Sendable {
    case bundle(String)
    case pid(pid_t)
}

/// Global focus generation. Incremented on every app activation; asynchronous
/// reads carry the generation they were started under and stale results are
/// dropped. It shares its source event with `Entry.focusTick` but serves a
/// different purpose: `focusTick` orders entries by recency.
public struct FocusGeneration: Hashable, Sendable, Comparable {
    public let raw: UInt64

    public init(raw: UInt64) { self.raw = raw }

    public static let initial = FocusGeneration(raw: 0)

    public func next() -> FocusGeneration { FocusGeneration(raw: raw &+ 1) }

    public static func < (a: Self, b: Self) -> Bool { a.raw < b.raw }
}

public enum TokenStability: Sendable {
    case stable
    case positional
}
