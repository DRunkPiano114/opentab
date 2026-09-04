import CoreGraphics
import Foundation
import os

/// Window number → `kCGWindowLayer`, from `CGWindowListCopyWindowInfo`. Used
/// only to confirm that an AX window exists in the window server and to read
/// its layer; names are never read.
///
/// The table is shared across all per-pid queues so a parallel sweep over 30
/// apps costs one copy, not thirty. A miss forces a fresh copy unless one was
/// taken within the last 100ms, so a window created after the last copy is
/// not falsely reported as absent.
final class CGWindowTable: Sendable {
    private struct State {
        var layers: [CGWindowID: Int32] = [:]
        var layerZeroOwners: Set<pid_t> = []
        var fetchedAt: ContinuousClock.Instant?
    }

    private static let maxAge: Duration = .seconds(1)
    private static let missRefreshAge: Duration = .milliseconds(100)

    private let state = OSAllocatedUnfairLock(initialState: State())

    func layer(of id: CGWindowID) -> Int32? {
        state.withLock { state in
            let now = ContinuousClock.now
            if let fetchedAt = state.fetchedAt, now - fetchedAt <= Self.maxAge {
                if let layer = state.layers[id] { return layer }
                if now - fetchedAt <= Self.missRefreshAge { return nil }
            }
            Self.refresh(&state, now: now)
            return state.layers[id]
        }
    }

    /// Processes that own at least one layer-0 window. Asking a process with
    /// none costs a full messaging timeout per attribute and yields nothing
    /// (WebKit content processes and other helpers answer `cannotComplete`),
    /// so the directory uses this as a candidate pre-filter. `.optionAll`
    /// keeps apps whose windows are all minimized or on another Space.
    func layerZeroOwnerPIDs() -> Set<pid_t> {
        state.withLock { state in
            let now = ContinuousClock.now
            if state.fetchedAt.map({ now - $0 > Self.maxAge }) ?? true {
                Self.refresh(&state, now: now)
            }
            return state.layerZeroOwners
        }
    }

    private static func refresh(_ state: inout State, now: ContinuousClock.Instant) {
        let info = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                    as? [[String: Any]]) ?? []
        var layers: [CGWindowID: Int32] = [:]
        var owners: Set<pid_t> = []
        layers.reserveCapacity(info.count)
        for row in info {
            guard let number = row[kCGWindowNumber as String] as? Int,
                  let layer = row[kCGWindowLayer as String] as? Int else { continue }
            layers[CGWindowID(number)] = Int32(layer)
            if layer == 0, let owner = row[kCGWindowOwnerPID as String] as? Int {
                owners.insert(pid_t(owner))
            }
        }
        state.layers = layers
        state.layerZeroOwners = owners
        state.fetchedAt = now
    }
}
