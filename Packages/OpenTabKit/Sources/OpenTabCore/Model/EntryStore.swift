import Foundation

/// In-memory table of entries plus the two monotonic counters. A value type:
/// the owner decides the isolation, and tests drive it with no concurrency.
public struct EntryStore: Sendable {
    public private(set) var entries: [EntryID: Entry] = [:]
    public var ignoreRules: IgnoreRules
    private var nextFocusTick: UInt64 = 1
    private var nextDiscoveryRank: UInt64 = 1

    public init(ignoreRules: IgnoreRules = IgnoreRules()) {
        self.ignoreRules = ignoreRules
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Replaces the window entries of `app` with `snapshots`.
    ///
    /// An empty read never deletes (L5): a Space change makes windows invisible
    /// to AX, and an empty array is indistinguishable from "all closed". The
    /// cost is zombie rows until the app terminates or the user rebuilds.
    ///
    /// Returns `true` when anything observable changed.
    @discardableResult
    public mutating func applyWindows(_ snapshots: [WindowSnapshot], for app: AppInfo,
                                      isHidden: Bool, bumpFocused: Bool = false) -> Bool {
        let kept = snapshots.filter { !ignoreRules.ignores($0) }
        guard !kept.isEmpty else { return false }

        var changed = false
        var seen: Set<EntryID> = []
        for snapshot in kept {
            let id = EntryID.window(snapshot.key)
            seen.insert(id)
            if var existing = entries[id] {
                let updated = Self.merge(snapshot, into: &existing, isHidden: isHidden)
                if bumpFocused, snapshot.isFocused {
                    existing.focusTick = nextFocusTick
                    nextFocusTick += 1
                    changed = true
                }
                if updated { changed = true }
                entries[id] = existing
            } else {
                var entry = Entry(id: id, kind: .window, key: snapshot.key, app: snapshot.app,
                                  title: snapshot.title, isMinimized: snapshot.isMinimized,
                                  isOnActiveSpace: snapshot.isOnActiveSpace, isHidden: isHidden,
                                  discoveryRank: nextDiscoveryRank)
                nextDiscoveryRank += 1
                if bumpFocused, snapshot.isFocused {
                    entry.focusTick = nextFocusTick
                    nextFocusTick += 1
                }
                entries[id] = entry
                changed = true
            }
        }

        let stale = entries.values.filter { $0.app.key == app.key && $0.kind == .window && !seen.contains($0.id) }
        for entry in stale {
            entries.removeValue(forKey: entry.id)
            changed = true
        }
        return changed
    }

    @discardableResult
    public mutating func removeApp(_ key: AppKey) -> Bool {
        let ids = entries.values.filter { $0.app.key == key }.map(\.id)
        for id in ids { entries.removeValue(forKey: id) }
        return !ids.isEmpty
    }

    @discardableResult
    public mutating func setHidden(_ hidden: Bool, for key: AppKey) -> Bool {
        var changed = false
        for (id, entry) in entries where entry.app.key == key && entry.isHidden != hidden {
            var entry = entry
            entry.isHidden = hidden
            entries[id] = entry
            changed = true
        }
        return changed
    }

    /// Marks `id` as the most recently used entry.
    @discardableResult
    public mutating func bumpFocus(_ id: EntryID) -> Bool {
        guard var entry = entries[id] else { return false }
        entry.focusTick = nextFocusTick
        nextFocusTick += 1
        entries[id] = entry
        return true
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    public func sorted(mode: SortMode = .recency) -> [Entry] {
        EntrySort.sorted(Array(entries.values), mode: mode)
    }

    public func groupCounts() -> GroupCounts {
        GroupCounts(entries: entries.values)
    }

    /// Returns `true` when a display-relevant field changed.
    private static func merge(_ snapshot: WindowSnapshot, into entry: inout Entry, isHidden: Bool) -> Bool {
        var changed = false
        if entry.title != snapshot.title { entry.title = snapshot.title; changed = true }
        if entry.app != snapshot.app { entry.app = snapshot.app; changed = true }
        if entry.isMinimized != snapshot.isMinimized { entry.isMinimized = snapshot.isMinimized; changed = true }
        if entry.isOnActiveSpace != snapshot.isOnActiveSpace { entry.isOnActiveSpace = snapshot.isOnActiveSpace; changed = true }
        if entry.isHidden != isHidden { entry.isHidden = isHidden; changed = true }
        return changed
    }
}
