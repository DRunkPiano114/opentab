import CoreGraphics
import Foundation

enum WindowServerIDs {
    private static let queue = DispatchQueue(label: "im.opentab.app.windowserver", qos: .utility)

    /// Every window number the WindowServer lists, for the store's sweep.
    /// `nil` when the call answered nothing: an empty table is a failed read,
    /// never evidence that windows are gone (L5). Names are not read (L16).
    /// The copy is an IPC to the WindowServer, so it runs off the main
    /// thread (L13).
    static func current() async -> Set<UInt32>? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: read()) }
        }
    }

    private static func read() -> Set<UInt32>? {
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]], !info.isEmpty else { return nil }
        var ids: Set<UInt32> = []
        ids.reserveCapacity(info.count)
        for row in info {
            if let number = row[kCGWindowNumber as String] as? Int { ids.insert(UInt32(number)) }
        }
        return ids
    }
}
