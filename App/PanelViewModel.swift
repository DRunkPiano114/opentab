import AppKit
import Observation
import OpenTabCore

/// What the SwiftUI panel renders. Written by `PanelController`, read by the
/// views. The row list is frozen while the panel is open: refreshes that land
/// meanwhile update rows in place and never reorder them.
@MainActor
@Observable
final class PanelViewModel {
    struct Row: Identifiable, Equatable {
        let id: EntryID
        /// Primary line: the app's display name.
        var appName: String
        /// Secondary line: the window title. Empty means the row has no
        /// subtitle and the primary line is vertically centred.
        var title: String
        /// Pre-rasterised at the row icon size; `nil` draws a placeholder.
        var icon: NSImage?
        /// Group count in the fixed right column; `nil` omits the column.
        var count: Int?
        var isMinimized: Bool

        static func placeholders(count: Int) -> [Row] {
            (0..<count).map { index in
                Row(id: EntryID(key: .ax(pid: 0, elementID: UInt64(index))),
                    appName: "Application", title: "Window \(index)", icon: nil,
                    count: index % 3 == 0 ? 2 : nil, isMinimized: false)
            }
        }
    }

    var rows: [Row] = []
    var selectedIndex: Int = 0
    /// False during the hover guard right after the panel appears, so a cursor
    /// that happens to rest on the panel cannot override the keyboard selection.
    var hoverEnabled = false
    /// False shows the onboarding message instead of the list.
    var accessibilityGranted = true
    var onHover: (Int) -> Void = { _ in }
    var onActivate: (Int) -> Void = { _ in }
}
