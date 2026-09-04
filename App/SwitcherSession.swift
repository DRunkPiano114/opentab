import AppKit
import ApplicationServices
import OpenTabCore
import os

/// The hold / tap / release state machine: idle until Option+Tab, engaged
/// while the panel is up, committed when Option is released. Enter (or the
/// search hotkey) moves it to the search state, where the app is active and
/// the text field owns the keyboard until commit or cancel.
@MainActor
final class SwitcherSession {
    /// Supplied by the owner; read once per open to refresh the frontmost app
    /// in the background while the cached list is already on screen.
    var frontmostApp: () -> AppInfo? = { nil }

    static let repeatInitialDelay: Duration = .milliseconds(500)
    static let repeatInterval: Duration = .milliseconds(60)

    private enum State {
        case idle
        case engaged
        case searching
    }

    private struct Parked {
        var presented: [Entry]
        var rows: [PanelViewModel.Row]
        var selection: Selection
        var query: String
        var isFiltered: Bool
        var index: EntrySearchIndex
    }

    private let coordinator: SwitcherCoordinator
    private let panel: PanelController
    private let hotKeys: HotKeyCenter
    private let model: PanelViewModel
    private let log = Log.make("session")

    private var state: State = .idle
    /// The modifier that opened the panel; its release commits.
    private var holdModifier: HoldModifier = .option
    /// The entries on screen, in presentation order; parallel to the rows.
    private var presented: [Entry] = []
    private var rows: [PanelViewModel.Row] = []
    private var selection = Selection(count: 0)
    private var repeatTask: Task<Void, Never>?
    /// Screen position of the last hover that was allowed to select.
    private var pointerLocation = NSPoint.zero
    private var searchIndex = EntrySearchIndex()
    private var query = ""
    /// The main list, parked while the second-level pane is up.
    private var parked: Parked?
    /// The script window the open pane is showing, and the app it belongs to.
    private var detailWindow: WindowKey?
    private var detailApp: AppInfo?
    private var detailRows: [DetailPane.Row] = []
    /// Match offsets of the last search, so the pane can emphasise them
    /// without ranking the query a second time.
    private var titleMatches: [EntryID: [Int]] = [:]
    /// Rows the user closed with Cmd+W. The store defers removals while the
    /// panel is up, so without this the row would come back on the next
    /// refresh.
    private var dismissed: Set<EntryID> = []
    private let commandKeys = DetailKeyMonitor()
    /// The app that was frontmost before search activated this one; it gets
    /// focus back when the search is cancelled.
    private var previousApp: NSRunningApplication?

    init(coordinator: SwitcherCoordinator, panel: PanelController,
         hotKeys: HotKeyCenter, model: PanelViewModel) {
        self.coordinator = coordinator
        self.panel = panel
        self.hotKeys = hotKeys
        self.model = model
    }

    func start() {
        hotKeys.onNavigationKey = { [weak self] key, phase, hold in self?.handle(key, phase, hold: hold) }
        hotKeys.onModifierReleased = { [weak self] modifier in self?.modifierReleased(modifier) }
        model.onHover = { [weak self] row in self?.hover(row) }
        model.onActivate = { [weak self] row in self?.activate(rowAt: row) }
        model.onDetailBack = { [weak self] in self?.exitDetail() }
        commandKeys.onCloseSelected = { [weak self] in self?.closeSelected() }
        coordinator.onChange = { [weak self] in self?.indexChanged() }
        panel.searchField.onTextChange = { [weak self] text in self?.queryChanged(text) }
        panel.searchField.onCommand = { [weak self] command in self?.searchCommand(command) }

        let trusted = AXIsProcessTrusted()
        model.accessibilityGranted = trusted
        hotKeys.registerPersistent()
        if trusted {
            hotKeys.installModifierMonitors()
        }
        log.info("session started trusted=\(trusted, privacy: .public)")
    }

    func accessibilityGranted() {
        model.accessibilityGranted = true
        hotKeys.installModifierMonitors()
    }

    /// The grant went away while running: the panel says so
    /// instead of showing a list that only decays.
    func accessibilityRevoked() {
        model.accessibilityGranted = false
        if state != .idle { close(restoreFocus: true) }
    }

    /// Nothing is on screen and no modal of ours should be blocked.
    var isIdle: Bool { state == .idle }

    /// The display topology changed: a visible panel is closed and reopened
    /// on the new layout.
    func screensChanged() {
        guard state != .idle else { return }
        panel.reposition(rowCount: rows.count)
    }

    // MARK: - Keys

    /// Without the Accessibility grant the global monitor never reports the
    /// Option release, so the persistent hotkey's own release must close the
    /// panel instead: degraded, but never stuck.
    private var modifierReleaseObservable: Bool { hotKeys.modifierMonitorsInstalled }

    private func handle(_ key: NavigationKey, _ phase: KeyPhase, hold: HoldModifier?) {
        let entered = ContinuousClock.now
        switch state {
        case .idle:
            // Only the persistent hotkeys are registered while idle.
            guard phase == .pressed else { return }
            switch key {
            case .next: open(startAtEnd: false, since: entered, hold: hold ?? .option)
            case .previous: open(startAtEnd: true, since: entered, hold: hold ?? .option)
            case .search:
                open(startAtEnd: false, since: entered, hold: hold ?? .option, commitOnReleasedModifier: false)
                enterSearch()
                return
            default: return
            }
            if state == .engaged {
                startRepeat(key)
            }
        case .engaged:
            stopRepeat()
            switch phase {
            case .pressed:
                apply(key)
                if Self.repeats(key), state == .engaged {
                    startRepeat(key)
                }
            case .released:
                if key == .next || key == .previous, !modifierReleaseObservable {
                    commit()
                }
            }
        case .searching:
            // Only the persistent hotkeys reach here; the field owns the rest.
            guard phase == .pressed else { return }
            switch key {
            case .next: move(by: 1)
            case .previous: move(by: -1)
            default: break
            }
        }
    }

    private func apply(_ key: NavigationKey) {
        switch key {
        case .next, .down: move(by: 1)
        case .previous, .up: move(by: -1)
        case .right: enterDetail()
        case .left: exitDetail()
        case .escape:
            if detailWindow != nil { exitDetail() } else { close() }
        case .commit, .search: enterSearch()
        }
    }

    private static func repeats(_ key: NavigationKey) -> Bool {
        switch key {
        case .next, .previous, .up, .down: true
        case .escape, .commit, .left, .right, .search: false
        }
    }

    /// Carbon hotkeys do not auto-repeat, so a held key is repeated here until
    /// its release, another key, or the panel closing.
    private func startRepeat(_ key: NavigationKey) {
        repeatTask = Task { [weak self] in
            try? await Task.sleep(for: Self.repeatInitialDelay)
            while !Task.isCancelled {
                guard let self, self.state == .engaged else { return }
                self.apply(key)
                try? await Task.sleep(for: Self.repeatInterval)
            }
        }
    }

    private func stopRepeat() {
        repeatTask?.cancel()
        repeatTask = nil
    }

    private func modifierReleased(_ modifier: HoldModifier) {
        guard state == .engaged, modifier == holdModifier else { return }
        commit()
    }

    // MARK: - Search

    /// Navigation to search: record who has focus, activate
    /// ourselves and hand the keyboard to the text field. The navigation
    /// hotkeys are released first: they are consumed system-wide and would
    /// otherwise starve the field of Return, Escape, Tab and the arrows.
    private func enterSearch() {
        guard state == .engaged else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        stopRepeat()
        hotKeys.unregisterNavigationKeys()
        state = .searching
        query = ""
        guard panel.enterSearch() else {
            log.error("search field did not become first responder; staying in navigation")
            state = .engaged
            hotKeys.registerNavigationKeys(for: holdModifier)
            return
        }
        commandKeys.start()
        log.notice("search entered previous=\(self.previousApp?.processIdentifier ?? 0, privacy: .public)")
    }

    private func queryChanged(_ text: String) {
        guard state == .searching, text != query else { return }
        let started = ContinuousClock.now
        query = text
        present(hits: searchIndex.search(text))
        log.notice("query len=\(text.count, privacy: .public) rows=\(self.rows.count, privacy: .public) took=\(Self.milliseconds(started.duration(to: .now)), format: .fixed(precision: 2), privacy: .public)ms")
    }

    /// Shows search results. An empty query is the recency list again and
    /// opens on the second row like a fresh open; a real query opens on its
    /// best hit.
    private func present(hits: [SearchHit]) {
        let filtered = !query.allSatisfy(\.isWhitespace)
        let visible = hits.filter { !dismissed.contains($0.entry.id) }
        presented = visible.map(\.entry)
        titleMatches = Dictionary(visible.map { ($0.entry.id, $0.titleMatches) },
                                  uniquingKeysWith: { first, _ in first })
        model.isFiltered = filtered
        selection = Selection(count: presented.count)
        if filtered { selection.select(0) }
        guard detailWindow == nil else {
            showDetail(scrollTo: selection.index)
            return
        }
        rows = filtered ? PanelController.rows(for: visible) : makeRows(presented)
        panel.present(rows: rows, selectedIndex: selection.index)
        panel.refit(rowCount: rows.count)
    }

    private func searchCommand(_ command: SearchFieldController.Command) {
        guard state == .searching else { return }
        switch command {
        case .moveDown, .moveNext: move(by: 1)
        case .moveUp, .movePrevious: move(by: -1)
        case .commit: commit()
        case .enterDetail: enterDetail()
        case .leaveDetail: exitDetail()
        case .cancel:
            if !query.isEmpty {
                panel.searchField.text = ""
                queryChanged("")
            } else if detailWindow != nil {
                exitDetail()
            } else {
                close(restoreFocus: true)
            }
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    // MARK: - The detail pane

    /// Second level: the tabs of the window the highlighted row stands for.
    /// A row with no tabs behind it stays put rather than opening an empty
    /// pane. Entered from the right arrow in either state.
    func enterDetail() {
        guard state != .idle, detailWindow == nil,
              presented.indices.contains(selection.index) else { return }
        let entry = presented[selection.index]
        guard let window = coordinator.scriptWindow(for: entry) else { return }
        let tabs = coordinator.tabs(in: window).filter { !dismissed.contains($0.id) }
        guard !tabs.isEmpty else { return }

        parked = Parked(presented: presented, rows: rows, selection: selection, query: query,
                        isFiltered: model.isFiltered, index: searchIndex)
        detailWindow = window
        detailApp = entry.app
        query = ""
        model.isFiltered = false
        if state == .searching { panel.searchField.text = "" }
        searchIndex = EntrySearchIndex()
        searchIndex.update(with: tabs)
        presented = tabs
        selection = Selection(count: tabs.count)
        // Opens on the tab the row stood for, so entering and leaving keeps
        // the same thing selected.
        selection.select(tabs.firstIndex { $0.id == entry.id } ?? 0)
        titleMatches = [:]
        showDetail(scrollTo: selection.index)
        log.notice("detail opened pid=\(entry.app.pid, privacy: .public) tabs=\(tabs.count, privacy: .public)")
    }

    /// Back to the main list, exactly as it was left.
    func exitDetail() {
        guard let parked else { return }
        detailWindow = nil
        detailApp = nil
        detailRows = []
        titleMatches = [:]
        presented = parked.presented.filter { !dismissed.contains($0.id) }
        rows = parked.rows.filter { !dismissed.contains($0.id) }
        selection = parked.selection
        selection.listChanged(count: rows.count, previousRowNowAt: min(selection.index, max(rows.count - 1, 0)))
        query = parked.query
        searchIndex = parked.index
        model.isFiltered = parked.isFiltered
        self.parked = nil
        if state == .searching { panel.searchField.text = query }
        panel.hideDetail(rows: rows, selectedIndex: selection.index)
    }

    /// Rebuilds the pane from the current rows and puts it on screen,
    /// rewinding the list the way a fresh main list is rewound.
    private func showDetail(scrollTo index: Int) {
        let pane = makeDetailPane()
        detailRows = pane.rows
        panel.showDetail(pane, selectedIndex: index)
        prefetchFavicons()
    }

    /// The same rebuild for a refresh that arrived on its own: the list must
    /// not scroll under the user.
    private func refreshDetail() {
        let pane = makeDetailPane()
        detailRows = pane.rows
        panel.refreshDetail(pane, selectedIndex: selection.index)
        prefetchFavicons()
    }

    private func makeDetailPane() -> DetailPane {
        DetailPane.make(app: detailApp,
                        appIcon: detailApp.flatMap { IconCache.shared.icon(for: $0) },
                        tabs: presented, matches: titleMatches,
                        isFiltered: model.isFiltered, favicon: favicon)
    }

    private func favicon(for entry: Entry) -> NSImage? {
        FaviconStore.shared.icon(for: entry.url, pointSize: DetailMetrics.faviconSize)
    }

    /// Favicons arrive after the pane is already drawn; the pane is rebuilt
    /// once when a batch lands, so a row that started on the app icon picks
    /// up its own.
    private func prefetchFavicons() {
        let urls = presented.compactMap(\.url)
        guard !urls.isEmpty else { return }
        FaviconStore.shared.prefetch(urls) { [weak self] in
            guard let self, self.detailWindow != nil else { return }
            let pane = self.makeDetailPane()
            guard pane.rows != self.detailRows else { return }
            self.detailRows = pane.rows
            self.model.detail = pane
        }
    }

    /// Cmd+W: closes the selected tab where it is and takes its row out.
    /// Search state only - the panel is key there, so the chord is ours; in
    /// navigation it would also reach the app in front.
    func closeSelected() {
        guard state == .searching, presented.indices.contains(selection.index) else { return }
        let entry = presented[selection.index]
        guard entry.kind == .tab else { return }
        let coordinator = coordinator
        Task { [weak self] in
            guard await coordinator.closeTab(entry) else { return }
            self?.rowClosed(entry.id)
        }
    }

    private func rowClosed(_ id: EntryID) {
        guard state != .idle else { return }
        dismissed.insert(id)
        guard let index = presented.firstIndex(where: { $0.id == id }) else { return }
        presented.remove(at: index)
        if detailWindow != nil {
            if presented.isEmpty {
                exitDetail()
                return
            }
            selection.listChanged(count: presented.count,
                                  previousRowNowAt: min(index, presented.count - 1))
            refreshDetail()
        } else {
            rows.remove(at: index)
            selection.listChanged(count: rows.count, previousRowNowAt: min(index, max(rows.count - 1, 0)))
            panel.update(rows: rows, selectedIndex: selection.index)
            panel.refit(rowCount: rows.count)
        }
        log.notice("tab closed in place; rows=\(self.presented.count, privacy: .public)")
    }

    // MARK: - Panel

    private func open(startAtEnd: Bool, since entered: ContinuousClock.Instant, hold: HoldModifier,
                      commitOnReleasedModifier: Bool = true) {
        holdModifier = hold
        presented = coordinator.entries
        searchIndex.update(with: presented)
        rows = makeRows(presented)
        selection = Selection(count: rows.count)
        if startAtEnd {
            selection.select(rows.count - 1)
        }
        state = .engaged
        coordinator.setPanelVisible(true)
        pointerLocation = NSEvent.mouseLocation
        panel.show(rows: rows, selectedIndex: selection.index, since: entered)
        hotKeys.registerNavigationKeys(for: hold)
        log.notice("open rows=\(self.rows.count, privacy: .public) selected=\(self.selection.index, privacy: .public) hold=\(String(describing: hold), privacy: .public) held=\(self.hotKeys.isHeld(hold), privacy: .public) order=\(Self.describe(self.presented), privacy: .public)")

        if let app = frontmostApp() {
            Task { await coordinator.refresh(app: app) }
        }
        // A quick tap can release the modifier before the hotkey event reaches
        // us; the monitor's edge then arrives in idle and is ignored, so the
        // session's current key state settles it here. `NSEvent.modifierFlags`
        // is not usable for this: it reflects the last event this (inactive)
        // app processed, which once reported Option up while it was held and
        // committed the panel the instant it opened.
        if commitOnReleasedModifier, modifierReleaseObservable, !hotKeys.isHeld(hold) {
            commit()
        }
    }

    /// A refresh while the panel is up. With a query on screen the results
    /// are ranked again; otherwise the list keeps its order and only takes
    /// updates and additions, so rows never jump under the highlight.
    private func indexChanged() {
        guard state != .idle else { return }
        if let window = detailWindow {
            detailChanged(in: window)
            return
        }
        let fresh = coordinator.entries
        searchIndex.update(with: fresh)
        let selectedID = presented.indices.contains(selection.index) ? presented[selection.index].id : nil

        if state == .searching, model.isFiltered {
            let hits = searchIndex.search(query)
            presented = hits.map(\.entry)
            rows = PanelController.rows(for: hits)
            let newIndex = selectedID.flatMap { id in presented.firstIndex { $0.id == id } }
            selection.listChanged(count: rows.count, previousRowNowAt: newIndex)
            panel.update(rows: rows, selectedIndex: selection.index)
            panel.refit(rowCount: rows.count)
            return
        }
        var byID: [EntryID: Entry] = [:]
        for entry in fresh {
            byID[entry.id] = entry
        }

        var kept: [Entry] = []
        var seen: Set<EntryID> = []
        for entry in presented {
            guard let updated = byID[entry.id] else { continue }
            kept.append(updated)
            seen.insert(entry.id)
        }
        for entry in fresh where !seen.contains(entry.id) && !dismissed.contains(entry.id) {
            kept.append(entry)
        }

        presented = kept
        rows = makeRows(kept)
        let newIndex = selectedID.flatMap { id in kept.firstIndex { $0.id == id } }
        selection.listChanged(count: kept.count, previousRowNowAt: newIndex)
        panel.update(rows: rows, selectedIndex: selection.index)
        if state == .searching {
            panel.refit(rowCount: rows.count)
        }
    }

    /// A refresh while the pane is up touches only the pane. The window
    /// losing its last tab closes the pane rather than leaving it empty.
    private func detailChanged(in window: WindowKey) {
        let fresh = coordinator.tabs(in: window).filter { !dismissed.contains($0.id) }
        guard !fresh.isEmpty else {
            exitDetail()
            return
        }
        searchIndex.update(with: fresh)
        let selectedID = presented.indices.contains(selection.index) ? presented[selection.index].id : nil
        if model.isFiltered {
            let hits = searchIndex.search(query).filter { !dismissed.contains($0.entry.id) }
            presented = hits.map(\.entry)
            titleMatches = Dictionary(hits.map { ($0.entry.id, $0.titleMatches) },
                                      uniquingKeysWith: { first, _ in first })
        } else {
            presented = fresh
            titleMatches = [:]
        }
        let newIndex = selectedID.flatMap { id in presented.firstIndex { $0.id == id } }
        selection.listChanged(count: presented.count, previousRowNowAt: newIndex)
        refreshDetail()
    }

    private func makeRows(_ entries: [Entry]) -> [PanelViewModel.Row] {
        PanelController.rows(for: entries, counts: coordinator.groupCounts, status: coordinator.rowStatus)
    }

    private func move(by delta: Int) {
        guard state != .idle, !selection.isEmpty else { return }
        selection.advance(by: delta)
        panel.select(selection.index, source: .keyboard)
        log.notice("select index=\(self.selection.index, privacy: .public) via=key \(self.describeSelected(), privacy: .public)")
    }

    private func hover(_ row: Int) {
        guard state != .idle, model.hoverEnabled, presented.indices.contains(row) else { return }
        // A keyboard scroll slides a different row under a resting cursor and
        // the view reports that as a hover; only a cursor that moved may select.
        let location = NSEvent.mouseLocation
        guard location != pointerLocation else { return }
        pointerLocation = location
        guard row != selection.index else { return }
        selection.select(row)
        panel.select(selection.index, source: .pointer)
        log.notice("select index=\(self.selection.index, privacy: .public) via=hover \(self.describeSelected(), privacy: .public)")
    }

    /// "pid:focusTick" per row, first rows only; never titles.
    private static func describe(_ entries: [Entry]) -> String {
        entries.prefix(8).map { "\($0.app.pid):\($0.focusTick)" }.joined(separator: ",")
    }

    private func describeSelected() -> String {
        guard presented.indices.contains(selection.index) else { return "none" }
        let entry = presented[selection.index]
        return "pid=\(entry.app.pid) key=\(entry.key)"
    }

    private func activate(rowAt row: Int) {
        guard state != .idle, presented.indices.contains(row) else { return }
        selection.select(row)
        commit()
    }

    private func commit() {
        guard state != .idle else { return }
        let target = presented.indices.contains(selection.index) ? presented[selection.index] : nil
        // With nothing to activate, focus must still go back where it was.
        close(restoreFocus: target == nil)
        guard let target else { return }
        log.notice("commit pid=\(target.app.pid, privacy: .public) kind=\(String(describing: target.kind), privacy: .public) key=\(String(describing: target.key), privacy: .public)")
        let coordinator = coordinator
        Task { await coordinator.activate(target) }
    }

    /// `restoreFocus` hands activation back to the app that had it before
    /// search activated us; a commit skips it because the activator is about
    /// to make the target frontmost.
    private func close(restoreFocus: Bool = false) {
        stopRepeat()
        commandKeys.stop()
        let wasSearching = state == .searching
        state = .idle
        detailWindow = nil
        detailApp = nil
        detailRows = []
        parked = nil
        dismissed.removeAll()
        panel.hide()
        coordinator.setPanelVisible(false)
        hotKeys.unregisterNavigationKeys()
        presented = []
        rows = []
        selection = Selection(count: 0)
        query = ""
        model.isFiltered = false
        if wasSearching, restoreFocus, NSApp.isActive, let previousApp {
            NSApp.yieldActivation(to: previousApp)
            let restored = previousApp.activate(options: [])
            log.notice("restore focus pid=\(previousApp.processIdentifier, privacy: .public) requested=\(restored, privacy: .public)")
        }
        previousApp = nil
    }
}
