import CoreGraphics
import Foundation

enum WindowServerIDs {
    /// Every window number the WindowServer lists, for the store's sweep.
    /// `nil` when the call answered nothing: an empty table is a failed read,
    /// never evidence that windows are gone (L5). Names are not read (L16).
    static func current() -> Set<UInt32>? {
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
