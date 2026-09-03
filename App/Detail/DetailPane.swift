import AppKit
import OpenTabCore
import SwiftUI

/// What the second-level pane renders: one window's tabs.
///
/// Three differences from the main list are deliberate and must not be
/// unified away (ui-spec.md §3): the main list draws the app icon and this
/// one draws a favicon, the main list has no row separators and this one
/// does, and the main list truncates a title to one line while this one wraps
/// to two.
struct DetailPane: Equatable {
    struct Row: Identifiable, Equatable {
        let id: EntryID
        var title: String
        /// `nil` draws the app icon: a favicon that could not be found must
        /// degrade to something, never to a blank square.
        var favicon: NSImage?
        /// Character offsets to emphasise while the pane is filtered.
        var titleMatches: [Int] = []
    }

    var appName: String
    var appIcon: NSImage?
    var rows: [Row]
    /// Shown in the field while the pane is being searched.
    var searchPlaceholder: String
    /// True once a query has been typed, so an empty result reads as
    /// "no matches" rather than "no tabs".
    var isFiltered = false
}

/// Layout tokens for the detail pane (ui-spec.md §2). The measured values are
/// the chip, icon, divider, pitch, height, inset and favicon; the vertical
/// gaps between the header elements were not measured and are chosen here.
enum DetailMetrics {
    static let backChipSize = CGSize(width: 61, height: 30)
    static let backChipLeading: CGFloat = 18
    static let backChipTop: CGFloat = 14
    static let appIconSize: CGFloat = 33
    static let dividerInset: CGFloat = 18
    static let dividerThickness: CGFloat = 1
    static let rowPitch: CGFloat = 52
    static let rowHeight: CGFloat = 45
    static let rowInset: CGFloat = 16
    static let faviconSize: CGFloat = 18
    static let faviconTextGap: CGFloat = 10
    static let rowRadius: CGFloat = 9
    static let titleLineLimit = 2

    static let chipIconGap: CGFloat = 10
    static let iconNameGap: CGFloat = 6
    static let nameDividerGap: CGFloat = 12
    static let dividerFieldGap: CGFloat = 12
    static let fieldListGap: CGFloat = 12
    static let bottomPad: CGFloat = 12

    static let headerFont = Font.system(size: 17, weight: .bold)
    static let rowTitleFont = Font.system(size: 13.5, weight: .regular)
    static let rowTitleMatchFont = Font.system(size: 13.5, weight: .bold)

    /// Everything above the first row.
    static let headerHeight: CGFloat = backChipTop + backChipSize.height + chipIconGap
        + appIconSize + iconNameGap + nameLineHeight + nameDividerGap
        + dividerThickness + dividerFieldGap + Theme.fieldHeight + fieldListGap

    /// 17pt bold on the system font; fixed so the header never reflows.
    private static let nameLineHeight: CGFloat = 21

    static func height(rowCount: Int, visibleHeight: CGFloat?) -> CGFloat {
        let rowGap = rowPitch - rowHeight
        let natural = headerHeight + CGFloat(max(rowCount, 1)) * rowPitch - rowGap + bottomPad
        let oneRow = headerHeight + rowPitch - rowGap + bottomPad
        guard let visibleHeight else { return natural }
        return max(min(natural, visibleHeight - PanelController.Metrics.screenInset), oneRow)
    }
}

extension DetailPane {
    /// The pane for one window's tabs. `favicon` is asked per row so a lookup
    /// that finds nothing leaves the app icon in place instead of a blank.
    static func make(app: AppInfo?, appIcon: NSImage?, tabs: [Entry],
                     matches: [EntryID: [Int]], isFiltered: Bool,
                     favicon: (Entry) -> NSImage?) -> DetailPane {
        let name = app?.localizedName ?? ""
        return DetailPane(appName: name, appIcon: appIcon,
                          rows: rows(for: tabs, matches: matches, favicon: favicon),
                          searchPlaceholder: "Search tabs in \(name)",
                          isFiltered: isFiltered)
    }

    static func rows(for tabs: [Entry], matches: [EntryID: [Int]],
                     favicon: (Entry) -> NSImage?) -> [Row] {
        tabs.map { tab in
            Row(id: tab.id, title: tab.title, favicon: favicon(tab),
                titleMatches: matches[tab.id] ?? [])
        }
    }
}
