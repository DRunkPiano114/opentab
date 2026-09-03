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
        panel.contentView = hosting
    }

    var isVisible: Bool { panel.isVisible }

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

    /// Selection-only change: the rows are untouched, so the list is not
    /// diffed on every auto-repeat tick.
    func select(_ index: Int, source: PanelViewModel.SelectionSource) {
        model.select(index, source: source)
    }

    func hide() {
        hoverGuard?.cancel()
        hoverGuard = nil
        model.hoverEnabled = false
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

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
