import CoreGraphics
import Foundation
import os

/// One row of `CGWindowListCopyWindowInfo`. Names are never read (L16).
struct WindowRow: Sendable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    let layer: Int32
    let bounds: CGRect
    let alpha: Double
    let isOnscreen: Bool
}

/// The WindowServer's window list, grouped by owner, cached briefly so a
/// parallel refresh over thirty apps costs one copy. This is where the
/// windows AX cannot see come from: every layer-0 row of a pid that the AX
/// enumeration did not return is a candidate for the token scan.
final class WindowServerTable: Sendable {
    private struct State {
        var rowsByPID: [pid_t: [WindowRow]]?
        var fetchedAt: ContinuousClock.Instant?
    }

    private static let maxAge: Duration = .milliseconds(300)
    /// A CGWindowList row is not a window (L4): shadows, tooltips and
    /// toolbar fragments sit at layer 0 too. Anything smaller than this on a
    /// side, or fully transparent, is not worth a token scan; a real window
    /// the filter would drop is still listed whenever AX reaches it.
    static let minimumSide: CGFloat = 64

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// `nil` when the WindowServer answered nothing at all: an empty list
    /// for the whole session is a failed call, never a fact about windows,
    /// and pruning on it would delete rows (L5). The previous table stands
    /// until the next successful read.
    func rows(ownedBy pid: pid_t) -> [WindowRow]? {
        state.withLock { state in
            let now = ContinuousClock.now
            if state.fetchedAt.map({ now - $0 > Self.maxAge }) ?? true {
                if let fresh = Self.read() { state.rowsByPID = fresh }
                state.fetchedAt = now
            }
            return state.rowsByPID.map { $0[pid] ?? [] }
        }
    }

    static func isCandidate(_ row: WindowRow) -> Bool {
        row.layer == 0 && row.alpha > 0
            && min(row.bounds.width, row.bounds.height) >= minimumSide
    }

    private static func read() -> [pid_t: [WindowRow]]? {
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]], !info.isEmpty else { return nil }
        var table: [pid_t: [WindowRow]] = [:]
        for entry in info {
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  let owner = entry[kCGWindowOwnerPID as String] as? Int else { continue }
            var bounds = CGRect.zero
            if let dictionary = entry[kCGWindowBounds as String] {
                bounds = CGRect(dictionaryRepresentation: dictionary as! CFDictionary) ?? .zero
            }
            let row = WindowRow(id: CGWindowID(number), pid: pid_t(owner),
                                layer: Int32(entry[kCGWindowLayer as String] as? Int ?? 0),
                                bounds: bounds,
                                alpha: entry[kCGWindowAlpha as String] as? Double ?? 1,
                                isOnscreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false)
            table[row.pid, default: []].append(row)
        }
        return table
    }
}
