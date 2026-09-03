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

    static let activationDeadline: Duration = .milliseconds(800)
    static let repeatInitialDelay: Duration = .milliseconds(500)
    static let repeatInterval: Duration = .milliseconds(60)

    private enum State {
        case idle
        case engaged
        case searching
    }

    private let index: WindowIndex
    private let activator: any WindowActivator
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
    /// The app that was frontmost before search activated this one; it gets
    /// focus back when the search is cancelled.
    private var previousApp: NSRunningApplication?

    init(index: WindowIndex, activator: any WindowActivator, panel: PanelController,
         hotKeys: HotKeyCenter, model: PanelViewModel) {
        self.index = index
        self.activator = activator
        self.panel = panel
        self.hotKeys = hotKeys
        self.model = model
    }

    func start() {
        hotKeys.onNavigationKey = { [weak self] key, phase, hold in self?.handle(key, phase, hold: hold) }
        hotKeys.onModifierReleased = { [weak self] modifier in self?.modifierReleased(modifier) }
        model.onHover = { [weak self] row in self?.hover(row) }
        model.onActivate = { [weak self] row in self?.activate(rowAt: row) }
        index.onChange = { [weak self] in self?.indexChanged() }
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
        case .left, .right: break
        case .escape: close()
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

    /// Navigation to search (keymap.md §1): record who has focus, activate
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
        presented = hits.map(\.entry)
        rows = filtered ? PanelController.rows(for: hits) : PanelController.rows(for: presented, counts: index.groupCounts)
        selection = Selection(count: rows.count)
        if filtered { selection.select(0) }
        model.isFiltered = filtered
        panel.present(rows: rows, selectedIndex: selection.index)
        panel.refit(rowCount: rows.count)
    }

    private func searchCommand(_ command: SearchFieldController.Command) {
        guard state == .searching else { return }
        switch command {
        case .moveDown, .moveNext: move(by: 1)
        case .moveUp, .movePrevious: move(by: -1)
        case .commit: commit()
        case .cancel:
            if query.isEmpty {
                close(restoreFocus: true)
            } else {
                panel.searchField.text = ""
                queryChanged("")
            }
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    // MARK: - Panel

    private func open(startAtEnd: Bool, since entered: ContinuousClock.Instant, hold: HoldModifier,
                      commitOnReleasedModifier: Bool = true) {
        holdModifier = hold
        presented = index.entries
        searchIndex.update(with: presented)
        rows = PanelController.rows(for: presented, counts: index.groupCounts)
        selection = Selection(count: rows.count)
        if startAtEnd {
            selection.select(rows.count - 1)
        }
        state = .engaged
        pointerLocation = NSEvent.mouseLocation
        panel.show(rows: rows, selectedIndex: selection.index, since: entered)
        hotKeys.registerNavigationKeys(for: hold)
        log.notice("open rows=\(self.rows.count, privacy: .public) selected=\(self.selection.index, privacy: .public) hold=\(String(describing: hold), privacy: .public) held=\(self.hotKeys.isHeld(hold), privacy: .public) order=\(Self.describe(self.presented), privacy: .public)")

        if let app = frontmostApp() {
            Task { await index.refresh(app: app) }
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
        let fresh = index.entries
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
        for entry in fresh where !seen.contains(entry.id) {
            kept.append(entry)
        }

        presented = kept
        rows = PanelController.rows(for: kept, counts: index.groupCounts)
        let newIndex = selectedID.flatMap { id in kept.firstIndex { $0.id == id } }
        selection.listChanged(count: kept.count, previousRowNowAt: newIndex)
        panel.update(rows: rows, selectedIndex: selection.index)
        if state == .searching {
            panel.refit(rowCount: rows.count)
        }
    }

    private func move(by delta: Int) {
        guard state != .idle, !selection.isEmpty else { return }
        selection.advance(by: delta)
        panel.select(selection.index, source: .keyboard)
        log.notice("select index=\(self.selection.index, privacy: .public) via=key \(self.describeSelected(), privacy: .public)")
    }

    private func hover(_ row: Int) {
        guard state != .idle, model.hoverEnabled, rows.indices.contains(row) else { return }
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

    /// "pid:focusTick" per row, first rows only; never titles (L16).
    private static func describe(_ entries: [Entry]) -> String {
        entries.prefix(8).map { "\($0.app.pid):\($0.focusTick)" }.joined(separator: ",")
    }

    private func describeSelected() -> String {
        guard presented.indices.contains(selection.index) else { return "none" }
        let entry = presented[selection.index]
        return "pid=\(entry.app.pid) key=\(entry.key)"
    }

    private func activate(rowAt row: Int) {
        guard state != .idle, rows.indices.contains(row) else { return }
        selection.select(row)
        commit()
    }

    private func commit() {
        guard state != .idle else { return }
        let target = presented.indices.contains(selection.index) ? presented[selection.index] : nil
        // With nothing to activate, focus must still go back where it was.
        close(restoreFocus: target == nil)
        guard let target else { return }
        let key = target.key
        let pid = target.app.pid
        let activator = activator
        let log = log
        log.notice("commit pid=\(pid, privacy: .public) key=\(String(describing: key), privacy: .public)")
        Task {
            do {
                try await activator.activate(key, deadline: .now + Self.activationDeadline)
            } catch {
                log.error("activate failed pid=\(pid, privacy: .public) error=\(String(describing: error), privacy: .private)")
            }
        }
    }

    /// `restoreFocus` hands activation back to the app that had it before
    /// search activated us; a commit skips it because the activator is about
    /// to make the target frontmost.
    private func close(restoreFocus: Bool = false) {
        stopRepeat()
        let wasSearching = state == .searching
        state = .idle
        panel.hide()
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
