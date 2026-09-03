import Foundation
import os

/// Owns the `EntryStore` and keeps it current from a `WindowSource`, an
/// `AppDirectory` and a `RefreshTrigger`. Everything here runs on the main
/// actor; blocking system calls are the source's problem (L13).
@MainActor
public final class WindowIndex {
    public private(set) var store: EntryStore
    public var sortMode: SortMode = .recency
    /// Called after every observable change to `store`.
    public var onChange: (@MainActor () -> Void)?
    /// Per-app read budget. Warm reads take ~2ms; a wedged app costs at most
    /// the AX messaging timeout per attribute read.
    public var snapshotBudget: Duration = .milliseconds(600)
    /// How long after `didLaunchApplication` the launched app is read again.
    public var launchSettleDelay: Duration = .seconds(1)

    private let source: any WindowSource
    private let directory: any AppDirectory
    private var latestGeneration = FocusGeneration.initial
    private var latestSequence: [AppKey: UInt64] = [:]
    private var nextSequence: UInt64 = 1
    private var eventTask: Task<Void, Never>?
    private let log = Log.make("index")

    public init(source: any WindowSource, directory: any AppDirectory, ignoreRules: IgnoreRules = IgnoreRules()) {
        self.source = source
        self.directory = directory
        self.store = EntryStore(ignoreRules: ignoreRules)
    }

    public var entries: [Entry] { store.sorted(mode: sortMode) }
    public var groupCounts: GroupCounts { store.groupCounts() }

    /// Consumes `trigger.events` until `stop()`.
    public func start(trigger: any RefreshTrigger) {
        eventTask?.cancel()
        let events = trigger.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                await self.handle(event)
            }
        }
    }

    public func stop() {
        eventTask?.cancel()
        eventTask = nil
    }

    public func handle(_ event: RefreshEvent) async {
        switch event {
        case .appActivated(let app, let generation):
            latestGeneration = max(latestGeneration, generation)
            await refresh(app: app, bumpFocused: true, generation: generation)
        case .appLaunched(let app):
            // Launch is reported before the app has windows, and its activation
            // usually precedes them too; without the second read the first
            // window only shows up on the periodic tick, unfocused.
            await refresh(app: app)
            let delay = launchSettleDelay
            Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard let self else { return }
                let frontmost = self.directory.frontmostApp()?.key == app.key
                await self.refresh(app: app, bumpFocused: frontmost, generation: self.latestGeneration)
            }
        case .appTerminated(let app):
            if store.removeApp(app.key) { notify() }
        case .appHidden(let app):
            if store.setHidden(true, for: app.key) { notify() }
        case .appUnhidden(let app):
            if store.setHidden(false, for: app.key) { notify() }
        case .focusedWindowChanged(let app):
            await refresh(app: app, bumpFocused: true, generation: latestGeneration)
        case .titleChanged(let app):
            await refresh(app: app)
        case .periodic:
            await refreshAll()
        }
    }

    /// Reads every running app in parallel. Cold start on ~30 apps measures
    /// ~60ms this way versus ~550ms serially.
    ///
    /// `seedFocus` marks the frontmost app's focused window as most recent:
    /// a fresh store has every `focusTick` at zero, so without it the list
    /// opens in discovery order until the user switches apps.
    public func refreshAll(seedFocus: Bool = false) async {
        let apps = directory.runningApps().filter { !store.ignoreRules.ignores(app: $0) }
        let frontmost = seedFocus ? directory.frontmostApp()?.key : nil
        await withTaskGroup(of: Void.self) { group in
            for app in apps {
                group.addTask { await self.refresh(app: app, bumpFocused: app.key == frontmost, generation: self.latestGeneration) }
            }
        }
        let live = Set(apps.map(\.key))
        var changed = false
        for key in Set(store.entries.values.map(\.app.key)) where !live.contains(key) {
            if store.removeApp(key) { changed = true }
        }
        if changed { notify() }
    }

    /// Drops everything and re-reads. The user-visible escape hatch for the
    /// zombie rows that L5 guarantees.
    public func rebuild() async {
        store.removeAll()
        notify()
        await refreshAll(seedFocus: true)
    }

    /// Reads one app and applies the result. A result older than a later read
    /// of the same app is discarded; a focus bump is applied only while its
    /// generation is still the latest.
    public func refresh(app: AppInfo, bumpFocused: Bool = false,
                        generation: FocusGeneration? = nil) async {
        let sequence = nextSequence
        nextSequence += 1
        latestSequence[app.key] = sequence
        let deadline = ContinuousClock.now + snapshotBudget

        let snapshots: [WindowSnapshot]
        do {
            snapshots = try await source.snapshot(of: app, deadline: deadline)
        } catch {
            log.debug("snapshot failed pid=\(app.pid, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return
        }
        guard latestSequence[app.key] == sequence else { return }

        let bump = bumpFocused && (generation.map { $0 >= latestGeneration } ?? true)
        if bumpFocused {
            let focused = snapshots.contains(where: \.isFocused)
            log.notice("focus pid=\(app.pid, privacy: .public) windows=\(snapshots.count, privacy: .public) focusedFound=\(focused, privacy: .public) applied=\(bump, privacy: .public)")
        }
        let hidden = directory.isHidden(app)
        if store.applyWindows(snapshots, for: app, isHidden: hidden, bumpFocused: bump) {
            notify()
        }
    }

    private func notify() {
        log.info("index changed entries=\(self.store.entries.count, privacy: .public)")
        onChange?()
    }
}
