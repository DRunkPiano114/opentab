import AppKit
import ApplicationServices
import OpenTabCore
import os

/// The hold / tap / release state machine: idle until Option+Tab, engaged
/// while the panel is up, committed when Option is released.
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
    }

    private let index: WindowIndex
    private let activator: any WindowActivator
    private let panel: PanelController
    private let hotKeys: HotKeyCenter
    private let model: PanelViewModel
    private let log = Log.make("session")

    private var state: State = .idle
    /// The entries on screen, in presentation order; parallel to the rows.
    private var presented: [Entry] = []
    private var rows: [PanelViewModel.Row] = []
    private var selection = Selection(count: 0)
    private var repeatTask: Task<Void, Never>?

    init(index: WindowIndex, activator: any WindowActivator, panel: PanelController,
         hotKeys: HotKeyCenter, model: PanelViewModel) {
        self.index = index
        self.activator = activator
        self.panel = panel
        self.hotKeys = hotKeys
        self.model = model
    }

    func start() {
        hotKeys.onNavigationKey = { [weak self] key, phase in self?.handle(key, phase) }
        hotKeys.onModifierReleased = { [weak self] in self?.modifierReleased() }
        model.onHover = { [weak self] row in self?.hover(row) }
        model.onActivate = { [weak self] row in self?.activate(rowAt: row) }
        index.onChange = { [weak self] in self?.indexChanged() }

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

    private func handle(_ key: NavigationKey, _ phase: KeyPhase) {
        let entered = ContinuousClock.now
        switch state {
        case .idle:
            // Only the persistent Option+Tab hotkeys are registered while idle.
            guard phase == .pressed else { return }
            switch key {
            case .next: open(startAtEnd: false, since: entered)
            case .previous: open(startAtEnd: true, since: entered)
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
        }
    }

    private func apply(_ key: NavigationKey) {
        switch key {
        case .next, .down: move(by: 1)
        case .previous, .up: move(by: -1)
        case .left, .right: break
        case .escape: close()
        case .commit: commit()
        }
    }

    private static func repeats(_ key: NavigationKey) -> Bool {
        switch key {
        case .next, .previous, .up, .down: true
        case .escape, .commit, .left, .right: false
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

    private func modifierReleased() {
        guard state == .engaged else { return }
        commit()
    }

    // MARK: - Panel

    private func open(startAtEnd: Bool, since entered: ContinuousClock.Instant) {
        presented = index.entries
        rows = PanelController.rows(for: presented, counts: index.groupCounts)
        selection = Selection(count: rows.count)
        if startAtEnd {
            selection.select(rows.count - 1)
        }
        state = .engaged
        panel.show(rows: rows, selectedIndex: selection.index, since: entered)
        hotKeys.registerNavigationKeys()
        log.info("open rows=\(self.rows.count, privacy: .public) selected=\(self.selection.index, privacy: .public)")

        if let app = frontmostApp() {
            Task { await index.refresh(app: app) }
        }
        // A quick tap can release Option before the hotkey event reaches us;
        // the monitor's edge then arrives in idle and is ignored, so the
        // hardware state settles it here.
        if modifierReleaseObservable, !NSEvent.modifierFlags.contains(.option) {
            commit()
        }
    }

    private func indexChanged() {
        guard state == .engaged else { return }
        let fresh = index.entries
        var byID: [EntryID: Entry] = [:]
        for entry in fresh {
            byID[entry.id] = entry
        }
        let selectedID = presented.indices.contains(selection.index) ? presented[selection.index].id : nil

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
    }

    private func move(by delta: Int) {
        guard state == .engaged, !selection.isEmpty else { return }
        selection.advance(by: delta)
        panel.update(rows: rows, selectedIndex: selection.index)
    }

    private func hover(_ row: Int) {
        guard state == .engaged, model.hoverEnabled, rows.indices.contains(row) else { return }
        selection.select(row)
        panel.update(rows: rows, selectedIndex: selection.index)
    }

    private func activate(rowAt row: Int) {
        guard state == .engaged, rows.indices.contains(row) else { return }
        selection.select(row)
        commit()
    }

    private func commit() {
        guard state == .engaged else { return }
        let target = presented.indices.contains(selection.index) ? presented[selection.index] : nil
        close()
        guard let target else { return }
        let key = target.key
        let pid = target.app.pid
        let activator = activator
        let log = log
        Task {
            do {
                try await activator.activate(key, deadline: .now + Self.activationDeadline)
            } catch {
                log.error("activate failed pid=\(pid, privacy: .public) error=\(String(describing: error), privacy: .private)")
            }
        }
    }

    private func close() {
        stopRepeat()
        state = .idle
        panel.hide()
        hotKeys.unregisterNavigationKeys()
        presented = []
        rows = []
        selection = Selection(count: 0)
    }
}
