import AppKit
import Observation
import OpenTabCore
import SwiftUI

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
        var status: Status = .normal
        /// Character offsets to emphasise when the row is a search result.
        var appNameMatches: [Int] = []
        var titleMatches: [Int] = []

        /// A degraded state the row has to show rather than swallow: the
        /// count column carries a marker instead of a number.
        enum Status: Equatable {
            case normal
            /// The app's last read did not complete; the row is its last
            /// known state.
            case unresponsive
            /// A browser listed as windows only because Apple Events were
            /// refused.
            case tabsUnavailable
        }

        static func placeholders(count: Int) -> [Row] {
            (0..<count).map { index in
                Row(id: EntryID(key: .ax(pid: 0, elementID: UInt64(index))),
                    appName: "Application", title: "Window \(index)", icon: nil,
                    count: index % 3 == 0 ? 2 : nil, isMinimized: false)
            }
        }
    }

    enum Mode {
        /// Panel up, app inactive; Carbon hotkeys carry the keys.
        case navigating
        /// App active, the search field is first responder and owns the keys.
        case searching
    }

    enum SelectionSource {
        case keyboard, pointer
    }

    /// The view scrolls when this changes. `anchor` follows
    /// `ScrollViewProxy.scrollTo`: nil moves the list only as far as it takes
    /// to show the whole row.
    struct ScrollRequest: Equatable {
        var serial = 0
        var row = 0
        var anchor: UnitPoint?
    }

    var rows: [Row] = []
    var selectedIndex: Int = 0
    var mode: Mode = .navigating
    /// True once the search query is non-empty; the list then shows results.
    var isFiltered = false
    var scrollRequest = ScrollRequest()
    /// False during the hover guard right after the panel appears, so a cursor
    /// that happens to rest on the panel cannot override the keyboard selection.
    var hoverEnabled = false
    /// False shows the onboarding message instead of the list.
    var accessibilityGranted = true
    /// Bumped when a settings change alters the design tokens. The list is
    /// rebuilt on it: SwiftUI skips a row whose `Row` value did not change,
    /// which would leave that row on the old font.
    var styleGeneration = 0
    /// Non-nil while the second-level pane is up; the main list is then
    /// frozen behind it and comes back unchanged when the pane closes.
    var detail: DetailPane?
    var onHover: (Int) -> Void = { _ in }
    var onActivate: (Int) -> Void = { _ in }
    var onDetailBack: () -> Void = {}

    /// Replaces the list for a fresh open. The scroll view keeps its offset
    /// across shows, so the list is rewound to the top unless the panel opened
    /// backwards, in which case the last row is scrolled into view.
    func present(rows: [Row], selectedIndex: Int) {
        self.rows = rows
        self.selectedIndex = selectedIndex
        if selectedIndex <= 1 {
            scrollRequest = ScrollRequest(serial: scrollRequest.serial + 1, row: 0, anchor: .top)
        } else {
            scrollRequest = ScrollRequest(serial: scrollRequest.serial + 1, row: selectedIndex, anchor: nil)
        }
    }

    /// Replaces the second-level pane, or takes it down when `pane` is nil.
    /// Same scroll rule as `present(rows:selectedIndex:)`.
    func presentDetail(_ pane: DetailPane?, selectedIndex: Int) {
        detail = pane
        self.selectedIndex = selectedIndex
        scrollRequest = ScrollRequest(serial: scrollRequest.serial + 1, row: selectedIndex,
                                      anchor: selectedIndex == 0 ? .top : nil)
    }

    /// Only keyboard selections scroll. A pointer selection must never move
    /// the list: the row under the cursor would change, report a new hover,
    /// and the selection would chase itself down the list.
    func select(_ index: Int, source: SelectionSource) {
        selectedIndex = index
        if source == .keyboard {
            scrollRequest = ScrollRequest(serial: scrollRequest.serial + 1, row: index, anchor: nil)
        }
    }
}
