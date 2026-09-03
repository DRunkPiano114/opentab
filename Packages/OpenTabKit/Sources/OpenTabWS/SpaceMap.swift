import CoreGraphics
import Foundation
import os

/// Space membership by the set method (H19): a window is on an active Space
/// when the Spaces it belongs to intersect the set of every display's current
/// Space. `SLSWindowIsOnCurrentSpace` is not consulted (it answers `false`
/// for windows on the current Space), and a single "current Space" is not
/// enough with several displays.
public enum SpaceMembership {
    /// H20: some minimized windows belong to no Space at all, and a minimized
    /// window is reachable to AX regardless of Space, so an empty list falls
    /// back to `isMinimized`.
    public static func isOnActiveSpace(windowSpaces: [UInt64], activeSpaces: Set<UInt64>,
                                       isMinimized: Bool) -> Bool {
        if windowSpaces.isEmpty { return isMinimized }
        return windowSpaces.contains { activeSpaces.contains($0) }
    }
}

/// CGS Space queries: which Space each display shows now, and which Spaces a
/// window belongs to. No AX and no permission involved. Calls are serialised
/// behind one lock; the display topology is cached briefly because every
/// window of every app asks for it during one refresh.
final class SpaceMap: Sendable {
    struct Display: Sendable {
        let identifier: String
        let currentSpace: UInt64?
        let spaces: [UInt64]
    }

    private struct Cache {
        var displays: [Display] = []
        var fetchedAt: ContinuousClock.Instant?
    }

    private static let maxAge: Duration = .milliseconds(250)
    /// `CGSCopySpacesForWindows` mask for every Space kind.
    private static let allSpacesMask: Int32 = 0x7

    private let connection: Int32
    private let copySpacesForWindows: WSPrivateSymbols.CopySpacesForWindows
    private let copyManagedDisplaySpaces: WSPrivateSymbols.CopyManagedDisplaySpaces
    private let cache = OSAllocatedUnfairLock(initialState: Cache())

    /// `nil` when any of the three CGS symbols is missing (L10).
    init?() {
        guard let mainConnection = WSPrivateSymbols.mainConnectionID,
              let copySpaces = WSPrivateSymbols.copySpacesForWindows,
              let copyDisplays = WSPrivateSymbols.copyManagedDisplaySpaces else { return nil }
        connection = mainConnection()
        copySpacesForWindows = copySpaces
        copyManagedDisplaySpaces = copyDisplays
    }

    func displays() -> [Display] {
        cache.withLock { cache in
            let now = ContinuousClock.now
            if let fetchedAt = cache.fetchedAt, now - fetchedAt <= Self.maxAge { return cache.displays }
            cache.displays = readDisplays()
            cache.fetchedAt = now
            return cache.displays
        }
    }

    /// The union of every display's current Space.
    func activeSpaces() -> Set<UInt64> {
        Set(displays().compactMap(\.currentSpace))
    }

    func spaces(of windowID: CGWindowID) -> [UInt64] {
        cache.withLock { _ in
            let ids = [NSNumber(value: windowID)] as CFArray
            guard let array = copySpacesForWindows(connection, Self.allSpacesMask, ids)?.takeRetainedValue()
                    as? [NSNumber] else { return [] }
            return array.map(\.uint64Value)
        }
    }

    private func readDisplays() -> [Display] {
        guard let raw = copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return []
        }
        return raw.map { display in
            let identifier = display["Display Identifier"] as? String ?? "?"
            let current = Self.spaceID(display["Current Space"] as? [String: Any])
            let spaces = ((display["Spaces"] as? [[String: Any]]) ?? []).compactMap(Self.spaceID)
            return Display(identifier: identifier, currentSpace: current, spaces: spaces)
        }
    }

    private static func spaceID(_ space: [String: Any]?) -> UInt64? {
        guard let space else { return nil }
        return (space["ManagedSpaceID"] as? UInt64) ?? (space["id64"] as? UInt64)
    }
}
