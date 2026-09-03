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
        field.frame = Self.searchFieldFrame(in: container.bounds)
        field.autoresizingMask = [.width, .minYMargin]
        field.isHidden = true
        container.addSubview(field)
        panel.contentView = container
    }

    var isVisible: Bool { panel.isVisible }

    /// The field sits inside the backdrop `SwitcherRootView` draws for the
    /// search state, inset so the text lines up with the row content.
    private static func searchFieldFrame(in bounds: NSRect) -> NSRect {
        let inset = Theme.contentInsetH + Theme.fieldInsetH
        let height = Theme.fieldHeight - 2 * Theme.fieldTextInsetV
        return NSRect(x: inset,
                      y: bounds.maxY - Metrics.topPad - Theme.fieldHeight + Theme.fieldTextInsetV,
                      width: bounds.width - 2 * inset, height: height)
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
        let current = panel.frame
        let visibleHeight = panel.screen?.visibleFrame.height
        let size = Metrics.size(rowCount: rowCount, visibleHeight: visibleHeight)
        guard size.height != current.height else { return }
        let frame = NSRect(x: current.minX, y: current.maxY - size.height, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }

    func hide() {
        hoverGuard?.cancel()
        hoverGuard = nil
        model.hoverEnabled = false
        exitSearch()
        panel.orderOut(nil)
    }

    static func rows(for entries: [Entry], counts: GroupCounts) -> [PanelViewModel.Row] {
        entries.map { entry in
            PanelViewModel.Row(id: entry.id,
                               appName: entry.app.localizedName,
                               title: entry.title,
                               icon: IconCache.shared.icon(for: entry.app),
                               count: counts.displayCount(forApp: entry.app.key),
                               isMinimized: entry.isMinimized)
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
