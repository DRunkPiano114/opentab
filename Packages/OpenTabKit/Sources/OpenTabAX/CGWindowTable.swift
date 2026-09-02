import CoreGraphics
import Foundation
import os

/// Window number → `kCGWindowLayer`, from `CGWindowListCopyWindowInfo`. Used
/// only to confirm that an AX window exists in the window server and to read
/// its layer (L4); names are never read.
///
/// The table is shared across all per-pid queues so a parallel sweep over 30
/// apps costs one copy, not thirty. A miss forces a fresh copy unless one was
/// taken within the last 100ms, so a window created after the last copy is
/// not falsely reported as absent.
final class CGWindowTable: Sendable {
    private struct State {
        var layers: [CGWindowID: Int32] = [:]
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
            state.layers = Self.copy()
            state.fetchedAt = now
            return state.layers[id]
        }
    }

    private static func copy() -> [CGWindowID: Int32] {
        let info = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                    as? [[String: Any]]) ?? []
        var layers: [CGWindowID: Int32] = [:]
        layers.reserveCapacity(info.count)
        for row in info {
            guard let number = row[kCGWindowNumber as String] as? Int,
                  let layer = row[kCGWindowLayer as String] as? Int else { continue }
            layers[CGWindowID(number)] = Int32(layer)
        }
        return layers
    }
}
