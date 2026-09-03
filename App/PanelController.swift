import AppKit
import OpenTabCore
import SwiftUI
import os

/// Owns the panel window and its SwiftUI host. The window frame is computed
/// here from the layout tokens and fixed for the lifetime of one show; SwiftUI
/// fills whatever frame it is given.
@MainActor
final class PanelController {
    /// Layout tokens from reference/ui-spec.md §2.
    enum Metrics {
        static let width: CGFloat = 260
        static let topPad: CGFloat = 12
        static let fieldHeight: CGFloat = 36
        static let fieldListGap: CGFloat = 12
        static let rowPitch: CGFloat = 50
        static let rowGap: CGFloat = 4
        static let bottomPad: CGFloat = 12
        static let screenInset: CGFloat = 48
        static let prewarmRowCount = 30
        /// The onboarding message needs more than one row of height.
        static let onboardingRowCount = 3
        static let hoverGuard: Duration = .milliseconds(200)

        static func height(rowCount: Int, visibleHeight: CGFloat?) -> CGFloat {
            let chrome = topPad + fieldHeight + fieldListGap - rowGap + bottomPad
            let natural = chrome + CGFloat(max(rowCount, 1)) * rowPitch
            let oneRow = chrome + rowPitch
            guard let visibleHeight else { return natural }
            return max(min(natural, visibleHeight - screenInset), oneRow)
        }

        static func size(rowCount: Int, visibleHeight: CGFloat?) -> NSSize {
            NSSize(width: width, height: height(rowCount: rowCount, visibleHeight: visibleHeight))
        }
    }

    let panel: SwitcherPanel
    /// The AppKit text field of the search state. It is an AppKit sibling of
    /// the SwiftUI host rather than a SwiftUI-managed view so that first
    /// responder can be handed to it synchronously right after activation.
    let searchField = SearchFieldController()
    /// Hotkey handler entry to `orderFrontRegardless()` returning.
    private(set) var lastShowDuration: Duration?

    private let model: PanelViewModel
    private let hosting: NSHostingView<SwitcherRootView>
    private var hoverGuard: Task<Void, Never>?
    private let log = Log.make("panel")

    init(model: PanelViewModel) {
        self.model = model
        let size = Metrics.size(rowCount: Metrics.prewarmRowCount, visibleHeight: nil)
        panel = SwitcherPanel(contentRect: NSRect(origin: .zero, size: size))
        hosting = NSHostingView(rootView: SwitcherRootView(model: model))
        hosting.sizingOptions = []

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        let field = searchField.view
        field.frame = Self.searchFieldFrame(in: container.bounds, detail: false)
        field.autoresizingMask = [.width, .minYMargin]
        field.isHidden = true
        container.addSubview(field)
        panel.contentView = container
    }

    var isVisible: Bool { panel.isVisible }

    /// The field sits inside the backdrop the SwiftUI layer draws for the
    /// search state, inset so the text lines up with the row content. The two
    /// panes put that backdrop at different heights.
    private static func searchFieldFrame(in bounds: NSRect, detail: Bool) -> NSRect {
        let inset = Theme.contentInsetH + Theme.fieldInsetH
        let height = Theme.fieldHeight - 2 * Theme.fieldTextInsetV
        let topToField = detail
            ? DetailMetrics.headerHeight - DetailMetrics.fieldListGap - Theme.fieldHeight
            : Metrics.topPad
        return NSRect(x: inset,
                      y: bounds.maxY - topToField - Theme.fieldHeight + Theme.fieldTextInsetV,
                      width: bounds.width - 2 * inset, height: height)
    }

    /// Opens the second-level pane. The search field moves to the pane's own
    /// header position and takes the pane's placeholder.
    func showDetail(_ pane: DetailPane, selectedIndex: Int) {
        model.presentDetail(pane, selectedIndex: selectedIndex)
        searchField.placeholder = pane.searchPlaceholder
        refit(height: DetailMetrics.height(rowCount: pane.rows.count,
                                           visibleHeight: panel.screen?.visibleFrame.height))
        layoutSearchField()
    }

    /// A refresh inside the open pane: the rows are replaced without moving
    /// the list, the way `update(rows:selectedIndex:)` does for the main one.
    func refreshDetail(_ pane: DetailPane, selectedIndex: Int) {
        model.detail = pane
        model.selectedIndex = selectedIndex
        refit(height: DetailMetrics.height(rowCount: pane.rows.count,
                                           visibleHeight: panel.screen?.visibleFrame.height))
    }

    /// Takes the pane down and hands the main list back unchanged.
    func hideDetail(rows: [PanelViewModel.Row], selectedIndex: Int) {
        model.presentDetail(nil, selectedIndex: selectedIndex)
        model.rows = rows
        searchField.placeholder = SearchFieldController.defaultPlaceholder
        layoutSearchField()
        refit(rowCount: rows.count)
    }

    private func layoutSearchField() {
        guard let bounds = panel.contentView?.bounds else { return }
        searchField.view.frame = Self.searchFieldFrame(in: bounds, detail: model.detail != nil)
    }

    /// Refits to an explicit content height with the top edge fixed.
    func refit(height: CGFloat) {
        let current = panel.frame
        guard height != current.height else { return }
        let frame = NSRect(x: current.minX, y: current.maxY - height, width: current.width, height: height)
        panel.setFrame(frame, display: true)
        layoutSearchField()
    }

    /// SwiftUI's first layout pass in a process costs ~78ms against an 80ms
    /// budget; running it offscreen at launch leaves the second one at ~3ms.
    func prewarm() {
        model.rows = PanelViewModel.Row.placeholders(count: Metrics.prewarmRowCount)
        let size = Metrics.size(rowCount: Metrics.prewarmRowCount, visibleHeight: nil)
        panel.setFrame(NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size), display: false)
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.orderOut(nil)
        model.rows = []
    }

    /// Sizes and places the panel on the screen under the mouse and orders it
    /// front without activating the app. `since` is the instant the hotkey
    /// handler was entered, for `lastShowDuration`.
    func show(rows: [PanelViewModel.Row], selectedIndex: Int,
              since start: ContinuousClock.Instant = .now) {
        hoverGuard?.cancel()
        model.hoverEnabled = false
        model.present(rows: rows, selectedIndex: selectedIndex)

        let rowCount = model.accessibilityGranted ? rows.count : max(rows.count, Metrics.onboardingRowCount)
        if let screen = ScreenPlacement.screenUnderMouse() {
            let size = Metrics.size(rowCount: rowCount, visibleHeight: screen.visibleFrame.height)
            panel.setFrame(ScreenPlacement.frame(for: size, on: screen), display: false)
        } else {
            panel.setContentSize(Metrics.size(rowCount: rowCount, visibleHeight: nil))
        }
        panel.orderFrontRegardless()

        let elapsed = start.duration(to: .now)
        lastShowDuration = elapsed
        log.info("panel shown rows=\(rows.count, privacy: .public) show=\(Self.milliseconds(elapsed), format: .fixed(precision: 2), privacy: .public)ms")

        hoverGuard = Task { [weak self] in
            try? await Task.sleep(for: Metrics.hoverGuard)
            guard let self, !Task.isCancelled, self.panel.isVisible else { return }
            self.model.hoverEnabled = true
        }
    }

    func update(rows: [PanelViewModel.Row], selectedIndex: Int) {
        model.rows = rows
        model.selectedIndex = selectedIndex
    }

    /// A new list, as after a query change: the scroll position is reset
    /// the way a fresh show resets it.
    func present(rows: [PanelViewModel.Row], selectedIndex: Int) {
        model.present(rows: rows, selectedIndex: selectedIndex)
    }

    /// Selection-only change: the rows are untouched, so the list is not
    /// diffed on every auto-repeat tick.
    func select(_ index: Int, source: PanelViewModel.SelectionSource) {
        model.select(index, source: source)
    }

    /// Switches to the search state: activates the app, makes the panel key
    /// and focuses the field. Returns false when the field did not get an
    /// input context, in which case the caller stays in navigation.
    @discardableResult
    func enterSearch() -> Bool {
        let started = ContinuousClock.now
        model.mode = .searching
        model.isFiltered = false
        searchField.view.isHidden = false
        let ready = searchField.beginEditing(in: panel)
        log.info("search entered ready=\(ready, privacy: .public) took=\(Self.milliseconds(started.duration(to: .now)), format: .fixed(precision: 2), privacy: .public)ms")
        if !ready {
            exitSearch()
        }
        return ready
    }

    func exitSearch() {
        guard model.mode == .searching else { return }
        searchField.endEditing()
        searchField.view.isHidden = true
        model.mode = .navigating
        model.isFiltered = false
    }

    /// Refits the panel to `rowCount` rows with the top edge fixed, so a list
    /// that shrinks while the user types shrinks from the bottom.
    func refit(rowCount: Int) {
        refit(height: Metrics.size(rowCount: rowCount,
                                   visibleHeight: panel.screen?.visibleFrame.height).height)
    }

    /// The display topology changed under a visible panel: it is taken down
    /// and put back on the screen under the cursor, sized for that screen.
    func reposition(rowCount: Int) {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        let count = model.accessibilityGranted ? rowCount : max(rowCount, Metrics.onboardingRowCount)
        if let screen = ScreenPlacement.screenUnderMouse() {
            let size = Metrics.size(rowCount: count, visibleHeight: screen.visibleFrame.height)
            panel.setFrame(ScreenPlacement.frame(for: size, on: screen), display: false)
        } else {
            panel.setContentSize(Metrics.size(rowCount: count, visibleHeight: nil))
        }
        panel.orderFrontRegardless()
        log.notice("panel repositioned after a display change")
    }

    func hide() {
        hoverGuard?.cancel()
        hoverGuard = nil
        model.hoverEnabled = false
        exitSearch()
        model.detail = nil
        searchField.placeholder = SearchFieldController.defaultPlaceholder
        layoutSearchField()
        panel.orderOut(nil)
    }

    /// A window row counts its app's windows; a tab row counts the tabs of
    /// its window. Either count is omitted for a group of one.
    static func rows(for entries: [Entry], counts: GroupCounts,
                     status: (Entry) -> PanelViewModel.Row.Status = { _ in .normal }) -> [PanelViewModel.Row] {
        entries.map { entry in
            PanelViewModel.Row(id: entry.id,
                               appName: entry.app.localizedName,
                               title: entry.title,
                               icon: IconCache.shared.icon(for: entry.app),
                               count: count(for: entry, counts: counts),
                               isMinimized: entry.isMinimized,
                               status: status(entry))
        }
    }

    private static func count(for entry: Entry, counts: GroupCounts) -> Int? {
        switch entry.kind {
        case .window:
            return counts.displayCount(forApp: entry.app.key)
        case .tab:
            guard let tabs = counts.byWindowKey[entry.key], tabs > 1 else { return nil }
            return tabs
        }
    }

    /// Search results carry their match offsets and no count column.
    static func rows(for hits: [SearchHit]) -> [PanelViewModel.Row] {
        hits.map { hit in
            PanelViewModel.Row(id: hit.entry.id,
                               appName: hit.entry.app.localizedName,
                               title: hit.entry.title,
                               icon: IconCache.shared.icon(for: hit.entry.app),
                               count: nil,
                               isMinimized: hit.entry.isMinimized,
                               appNameMatches: hit.appNameMatches,
                               titleMatches: hit.titleMatches)
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
