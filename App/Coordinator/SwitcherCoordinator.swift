import AppKit
import OpenTabAX
import OpenTabCore
import OpenTabScript
import os

/// Owns the `TabStore` and keeps it current: window reads from the
/// `WindowSource`, tab reads from the providers, the periodic sweep against
/// the WindowServer, and activation. Everything here runs on the main actor;
/// blocking system calls stay behind the source, the activator and the
/// providers (L13).
///
/// The store keys a script window `.scripted(bundleID, token)`. Safari's
/// provider keys its windows by CGWindowID because that is what Safari's
/// dictionary exposes; those keys are re-keyed here to the scripted form and
/// the CGWindowID is handed to the store as a resolution (rule E-3), so a
/// Safari window is claimed without relying on its title.
@MainActor
final class SwitcherCoordinator {
    struct Configuration {
        /// Per-app window read. Warm reads take ~2ms; a wedged app costs the
        /// AX messaging timeout per attribute read.
        var snapshotBudget: Duration = .milliseconds(600)
        var tabReadBudget: Duration = ScriptBudget.read
        var activationBudget: Duration = .milliseconds(800)
        var tabActivationBudget: Duration = ScriptBudget.activate
        /// Resolving one `.ax` keyed window to a CGWindowID (K).
        var resolutionBudget: Duration = .milliseconds(300)
        /// A window that could not be resolved is left alone this long.
        var resolutionRetry: Duration = .seconds(60)
        /// How long after `didLaunchApplication` the launched app is read again.
        var launchSettleDelay: Duration = .seconds(1)
    }

    private(set) var store: TabStore
    var sortMode: SortMode = .recency
    var configuration = Configuration()
    /// Called after every observable change to the list.
    var onChange: (@MainActor () -> Void)?
    /// Apps whose latest window read did not complete. Their rows are shown
    /// as still reading and keep their last data (L5).
    private(set) var unresponsiveApps: Set<AppKey> = []

    private let source: any WindowSource
    private let activator: any WindowActivator
    private let directory: any AppDirectory
    private let providers: any TabProviderLookup
    private let gate: any AutomationGate
    private let resolver: (any WindowResolving)?
    private let windowServer: @Sendable () -> Set<UInt32>?
    private let lane = ReadLane<AppKey>()
    private var eventTask: Task<Void, Never>?
    /// K: resolved `.cg` key -> the `.ax` key the source cached the element
    /// under, and the reverse. Activation goes through the original key.
    private var aliasToSource: [WindowKey: WindowKey] = [:]
    private var aliasFromSource: [WindowKey: WindowKey] = [:]
    private var resolutionFailures: [WindowKey: ContinuousClock.Instant] = [:]
    private let log = Log.make("coordinator")

    init(source: any WindowSource, activator: any WindowActivator, directory: any AppDirectory,
         providers: any TabProviderLookup, gate: any AutomationGate, resolver: (any WindowResolving)?,
         windowServer: @escaping @Sendable () -> Set<UInt32>?, ignoreRules: IgnoreRules = IgnoreRules(),
         storeConfiguration: TabStore.Configuration = TabStore.Configuration()) {
        self.source = source
        self.activator = activator
        self.directory = directory
        self.providers = providers
        self.gate = gate
        self.resolver = resolver
        self.windowServer = windowServer
        self.store = TabStore(ignoreRules: ignoreRules, configuration: storeConfiguration)
    }

    /// The main list, one row per window.
    var entries: [Entry] { store.sorted(mode: sortMode) }
    var groupCounts: GroupCounts { store.groupCounts() }

    func rowStatus(for entry: Entry) -> PanelViewModel.Row.Status {
        if unresponsiveApps.contains(entry.app.key) { return .unresponsive }
        if gate.deniedBundleIDs.contains(entry.app.bundleID) { return .tabsUnavailable }
        return .normal
    }

    // MARK: - Events

    /// Consumes `trigger.events` until `stop()`.
    func start(trigger: any RefreshTrigger) {
        eventTask?.cancel()
        let events = trigger.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                await self.handle(event)
            }
        }
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
    }

    func handle(_ event: RefreshEvent) async {
        switch event {
        case .appActivated(let app, let generation):
            store.advanceGeneration(to: generation)
            await refresh(app: app, bumpFocused: true)
        case .appLaunched(let app):
            // Launch is reported before the app has windows, and its activation
            // usually precedes them too; without the second read the first
            // window only shows up on the periodic tick, unfocused.
            await refresh(app: app)
            let delay = configuration.launchSettleDelay
            Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard let self else { return }
                let frontmost = self.directory.frontmostApp()?.key == app.key
                await self.refresh(app: app, bumpFocused: frontmost)
            }
        case .appTerminated(let app):
            forget(app)
        case .appHidden(let app):
            if store.setHidden(true, for: app.key) { notify() }
        case .appUnhidden(let app):
            if store.setHidden(false, for: app.key) { notify() }
        case .focusedWindowChanged(let app):
            await refresh(app: app, bumpFocused: true)
        case .titleChanged(let app):
            await refresh(app: app)
        case .periodic:
            await reconcile()
        }
    }

    /// Reads one app's windows and, when it has a provider, its tabs.
    func refresh(app: AppInfo, bumpFocused: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.readWindows(of: app, bumpFocused: bumpFocused) }
            group.addTask { await self.readTabs(of: app) }
        }
    }

    /// Reads every running app in parallel. `seedFocus` marks the frontmost
    /// app's focused window as most recent: a fresh store has every
    /// `focusTick` at zero, so without it the list opens in discovery order.
    func refreshAll(seedFocus: Bool = false) async {
        let apps = candidates()
        let frontmost = seedFocus ? directory.frontmostApp()?.key : nil
        await withTaskGroup(of: Void.self) { group in
            for app in apps {
                group.addTask { await self.readWindows(of: app, bumpFocused: app.key == frontmost) }
            }
        }
    }

    /// The periodic tick and every "the cache may be wrong" transition: every
    /// app's windows, the WindowServer sweep (F), then every browser's tabs.
    func reconcile(seedFocus: Bool = false) async {
        await refreshAll(seedFocus: seedFocus)
        let apps = candidates()
        let live = windowServer()
        // The process table is only trusted alongside a WindowServer read:
        // the directory itself is filtered by window ownership, so a failed
        // read would report every app gone (L5).
        let running: Set<AppKey>? = (live == nil || apps.isEmpty) ? nil : Set(apps.map(\.key))
        if store.sweep(liveWindowIDs: live, runningApps: running) { notify() }
        await withTaskGroup(of: Void.self) { group in
            for app in apps where providers.provider(for: app) != nil {
                group.addTask { await self.readTabs(of: app) }
            }
        }
    }

    /// Drops everything and re-reads. The user-visible escape hatch for the
    /// zombie rows L5 guarantees (H7).
    func rebuild() async {
        store.removeAll()
        aliasToSource.removeAll()
        aliasFromSource.removeAll()
        resolutionFailures.removeAll()
        unresponsiveApps.removeAll()
        notify()
        await reconcile(seedFocus: true)
    }

    /// Removals are deferred while the panel is up and applied on close (H).
    func setPanelVisible(_ visible: Bool) {
        if store.setPanelVisible(visible) { notify() }
    }

    private func candidates() -> [AppInfo] {
        directory.runningApps().filter { !store.ignoreRules.ignores(app: $0) }
    }

    private func forget(_ app: AppInfo) {
        var changed = store.removeApp(app.key)
        if unresponsiveApps.remove(app.key) != nil { changed = true }
        for (alias, original) in aliasToSource where Self.pid(of: original) == app.pid {
            aliasToSource[alias] = nil
            aliasFromSource[original] = nil
        }
        resolutionFailures = resolutionFailures.filter { Self.pid(of: $0.key) != app.pid }
        if changed { notify() }
    }

    private static func pid(of key: WindowKey) -> pid_t? {
        if case .ax(let pid, _) = key { return pid }
        return nil
    }

    // MARK: - Window reads

    private func readWindows(of app: AppInfo, bumpFocused: Bool) async {
        let stamp = store.beginRead(for: app, kind: .windows)
        let deadline = ContinuousClock.now + configuration.snapshotBudget
        let snapshots: [WindowSnapshot]
        do {
            snapshots = try await source.snapshot(of: app, deadline: deadline)
        } catch let error as AXSourceError {
            windowReadFailed(app, error: error)
            return
        } catch {
            log.debug("window read failed pid=\(app.pid, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return
        }
        var changed = unresponsiveApps.remove(app.key) != nil
        let resolved = await resolveKeys(in: snapshots)
        let hidden = directory.isHidden(app)
        let result = store.applyWindows(resolved, for: app, isHidden: hidden, bumpFocused: bumpFocused, stamp: stamp)
        if bumpFocused, result.disposition == .applied {
            log.notice("focus pid=\(app.pid, privacy: .public) windows=\(snapshots.count, privacy: .public) focusedFound=\(snapshots.contains(where: \.isFocused), privacy: .public)")
        }
        if result.disposition == .applied, result.changed { changed = true }
        if changed { notify() }
    }

    /// A read that did not complete says nothing about the windows: the rows
    /// stay and are marked (L5). `apiDisabled` is the grant going away, which
    /// the accessibility watch reports; `invalidUIElement` is the process
    /// going away, which the termination event reports.
    private func windowReadFailed(_ app: AppInfo, error: AXSourceError) {
        log.notice("window read failed pid=\(app.pid, privacy: .public) error=\(error.name, privacy: .public)")
        switch error {
        case .deadlineExceeded, .cannotComplete:
            if unresponsiveApps.insert(app.key).inserted { notify() }
        case .notTrusted, .notImplemented, .invalidElement, .failure:
            break
        }
    }

    /// K: upgrades `.ax` keyed snapshots to `.cg` where the cascade can, and
    /// remembers the alias so activation still reaches the cached element.
    private func resolveKeys(in snapshots: [WindowSnapshot]) async -> [WindowSnapshot] {
        guard let resolver, snapshots.contains(where: { if case .ax = $0.key { true } else { false } }) else {
            return snapshots
        }
        var out = snapshots
        for (index, snapshot) in snapshots.enumerated() {
            guard case .ax = snapshot.key else { continue }
            if let known = aliasFromSource[snapshot.key] {
                out[index] = Self.rekeyed(snapshot, to: known)
                continue
            }
            if let failedAt = resolutionFailures[snapshot.key],
               ContinuousClock.now - failedAt < configuration.resolutionRetry { continue }
            let deadline = ContinuousClock.now + configuration.resolutionBudget
            guard let wid = await resolver.resolve(snapshot, deadline: deadline) else {
                resolutionFailures[snapshot.key] = .now
                continue
            }
            let alias = WindowKey.cg(wid)
            aliasToSource[alias] = snapshot.key
            aliasFromSource[snapshot.key] = alias
            resolutionFailures[snapshot.key] = nil
            out[index] = Self.rekeyed(snapshot, to: alias)
        }
        return out
    }

    private static func rekeyed(_ snapshot: WindowSnapshot, to key: WindowKey) -> WindowSnapshot {
        WindowSnapshot(key: key, app: snapshot.app, title: snapshot.title, subrole: snapshot.subrole,
                       isMinimized: snapshot.isMinimized, isOnActiveSpace: snapshot.isOnActiveSpace,
                       level: snapshot.level, isFocused: snapshot.isFocused)
    }

    // MARK: - Tab reads

    private func readTabs(of app: AppInfo) async {
        guard let provider = providers.provider(for: app) else { return }
        guard await gate.mayReadTabs(of: app) else { return }
        _ = await readTabsNow(of: app, provider: provider, coalesce: true)
    }

    /// One tab read through the app's lane (B), applied to the store. Returns
    /// the snapshots the provider answered with, or `nil` when it did not. A
    /// coalesced request may join a read that is already waiting, in which
    /// case it learns nothing about the result; callers that need the
    /// answer pass `coalesce: false`.
    private func readTabsNow(of app: AppInfo, provider: any TabProvider, coalesce: Bool) async -> [TabSnapshot]? {
        let box = OSAllocatedUnfairLock<[TabSnapshot]?>(initialState: nil)
        await lane.run(app.key, coalesce: coalesce) {
            let read = await self.performTabRead(of: app, provider: provider)
            box.withLock { $0 = read }
        }
        return box.withLock { $0 }
    }

    private func performTabRead(of app: AppInfo, provider: any TabProvider) async -> [TabSnapshot]? {
        let stamp = store.beginRead(for: app, kind: .tabs)
        let deadline = ContinuousClock.now + configuration.tabReadBudget
        let snapshots: [TabSnapshot]
        do {
            snapshots = try await provider.readTabs(for: app, deadline: deadline)
        } catch let error as ScriptError {
            await tabReadFailed(app, error: error)
            return nil
        } catch {
            log.debug("tab read failed pid=\(app.pid, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
        }
        let rekeyed = rekeyScriptWindows(in: snapshots, app: app)
        let result = store.applyTabs(rekeyed, for: app, stability: provider.tokenStability, stamp: stamp)
        if result.disposition == .applied {
            if result.changed { notify() }
            if !result.releasedWindows.isEmpty {
                await readWindows(of: app, bumpFocused: false)
            }
        }
        return rekeyed
    }

    /// Tab reads carry three kinds of failure (tab-providers.md §2): the
    /// target left, the grant is missing, or nothing conclusive.
    private func tabReadFailed(_ app: AppInfo, error: ScriptError) async {
        log.notice("tab read failed pid=\(app.pid, privacy: .public) error=\(String(describing: error), privacy: .public)")
        switch error {
        case .targetNotRunning:
            forget(app)
        case .notPermitted, .permissionUndetermined:
            gate.noteRefusal(of: app)
            await dropTabs(of: app)
        case .compileFailed:
            providers.markUnsupported(app)
            await dropTabs(of: app)
        case .timedOut, .indexRace, .notFound, .failed, .cancelled:
            break
        }
    }

    /// The provider is gone for this browser: its rows fall back to windows,
    /// which the store shows again once a window read lists them.
    private func dropTabs(of app: AppInfo) async {
        let result = store.removeTabs(for: app)
        if result.changed { notify() }
        if !result.releasedWindows.isEmpty {
            await readWindows(of: app, bumpFocused: false)
        }
    }

    /// A provider that keys windows by CGWindowID has told us the resolution
    /// for free: the key becomes the scripted form the store expects and the
    /// CGWindowID goes in as rule E-3 input.
    private func rekeyScriptWindows(in snapshots: [TabSnapshot], app: AppInfo) -> [TabSnapshot] {
        var resolved: Set<UInt32> = []
        let rekeyed = snapshots.map { snapshot -> TabSnapshot in
            guard case .cg(let wid) = snapshot.windowKey else { return snapshot }
            resolved.insert(wid)
            return TabSnapshot(windowKey: Self.scriptedKey(for: wid, app: app), token: snapshot.token,
                               title: snapshot.title, url: snapshot.url, isActive: snapshot.isActive,
                               isPrivate: snapshot.isPrivate)
        }
        for wid in resolved {
            let result = store.resolve(window: .cg(wid), toScriptWindow: Self.scriptedKey(for: wid, app: app))
            if result.changed { notify() }
        }
        return rekeyed
    }

    private static func scriptedKey(for wid: UInt32, app: AppInfo) -> WindowKey {
        .scripted(bundleID: app.bundleID, token: String(wid))
    }

    // MARK: - Activation (I)

    func activate(_ entry: Entry) async {
        if entry.kind == .tab {
            await activateTab(entry)
        } else {
            await activateWindow(entry)
        }
    }

    private func activateWindow(_ entry: Entry) async {
        let key = aliasToSource[entry.key] ?? entry.key
        do {
            try await activator.activate(key, deadline: .now + configuration.activationBudget)
        } catch AXActivationError.unknownWindow {
            // No element behind the row: a cached off-space snapshot, or a
            // launch that has not been read yet. The app is activated instead
            // and a read settles whether the window is still there.
            log.notice("no element for pid=\(entry.app.pid, privacy: .public); activating the app")
            Self.activateApp(entry.app)
            await readWindows(of: entry.app, bumpFocused: true)
        } catch {
            // A timeout is unknown, not failure (I).
            log.error("activate failed pid=\(entry.app.pid, privacy: .public) error=\(String(describing: error), privacy: .private)")
        }
    }

    private enum Landing {
        case landed
        case unknown
        /// The provider reported the tab gone and no read could be taken:
        /// direct evidence, so the entry goes (I).
        case gone
        /// A read taken after the selection was applied to the store and did
        /// not show the expected tab active; `retry` is the tab that now
        /// carries the expected identity, if any.
        case missed(retry: TabSnapshot?)
    }

    /// Raises the claimed window (which works across Spaces through the AX
    /// element), then has the provider select the tab and reads back where
    /// it landed. Safari selects tabs by index, so a tab closed between the
    /// read and now lands on its neighbour and reports success; the
    /// read-back is what catches that, and one retry follows it.
    private func activateTab(_ entry: Entry) async {
        guard let token = entry.id.tabToken, let provider = providers.provider(for: entry.app) else {
            await activateWindow(entry)
            return
        }
        if let window = store.claimedWindow(for: entry.key) {
            let key = aliasToSource[window] ?? window
            do {
                try await activator.activate(key, deadline: .now + configuration.activationBudget)
            } catch {
                log.notice("window raise before tab select pid=\(entry.app.pid, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }
        var target = TabSnapshot(windowKey: entry.key, token: token, title: entry.title, url: entry.url,
                                 isActive: false, isPrivate: entry.isPrivate)
        for attempt in 0..<2 {
            switch await select(target, provider: provider, app: entry.app) {
            case .landed, .unknown:
                return
            case .gone:
                if store.activationFailed(entry.id) { notify() }
                return
            case .missed(let retry):
                guard attempt == 0, let retry else { return }
                log.notice("tab activation missed pid=\(entry.app.pid, privacy: .public); retrying once")
                target = retry
            }
        }
    }

    private func select(_ tab: TabSnapshot, provider: any TabProvider, app: AppInfo) async -> Landing {
        do {
            try await provider.activate(tab, deadline: .now + configuration.tabActivationBudget)
        } catch let error as ScriptError {
            log.notice("tab select failed pid=\(app.pid, privacy: .public) error=\(String(describing: error), privacy: .public)")
            switch error {
            case .timedOut, .cancelled:
                return .unknown
            case .targetNotRunning:
                forget(app)
                return .unknown
            case .notPermitted, .permissionUndetermined:
                gate.noteRefusal(of: app)
                await dropTabs(of: app)
                return .unknown
            case .compileFailed:
                providers.markUnsupported(app)
                await dropTabs(of: app)
                return .unknown
            case .notFound, .indexRace, .failed:
                guard let tabs = await readTabsNow(of: app, provider: provider, coalesce: false) else { return .gone }
                return Self.landing(of: tab, stability: provider.tokenStability, in: tabs, selected: false)
            }
        } catch {
            return .unknown
        }
        guard let tabs = await readTabsNow(of: app, provider: provider, coalesce: false) else { return .unknown }
        return Self.landing(of: tab, stability: provider.tokenStability, in: tabs, selected: true)
    }

    /// Where the provider's selection landed, judged by a read taken after
    /// it (which the store has already absorbed, so a closed tab is gone
    /// from the list by now). `selected` is false when the provider already
    /// reported the tab missing; the read then only serves to find a
    /// replacement.
    private static func landing(of expected: TabSnapshot, stability: TokenStability, in tabs: [TabSnapshot],
                        selected: Bool) -> Landing {
        let window = tabs.filter { $0.windowKey == expected.windowKey }
        guard !window.isEmpty else { return tabs.isEmpty ? .unknown : .missed(retry: nil) }
        func matches(_ tab: TabSnapshot) -> Bool {
            switch stability {
            case .stable:
                return tab.token == expected.token
            case .positional:
                return TitleCorroboration.corroborates(windowTitle: tab.title, tabTitle: expected.title)
            }
        }
        if selected, let active = window.first(where: \.isActive), matches(active) { return .landed }
        return .missed(retry: window.first(where: matches))
    }

    private static func activateApp(_ app: AppInfo) {
        _ = NSRunningApplication(processIdentifier: app.pid)?.activate(options: [])
    }

    private func notify() {
        log.info("list changed entries=\(self.store.entries.count, privacy: .public)")
        onChange?()
    }
}
