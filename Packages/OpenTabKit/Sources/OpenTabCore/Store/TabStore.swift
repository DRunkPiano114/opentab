import Foundation
import os

/// The reconciled table of window and tab entries (reconciliation A-J).
///
/// Two sources describe the same browser window: Accessibility keys it
/// `.cg(id)` and produces a window entry; a tab provider keys it
/// `.scripted(bundleID, token)` and produces tab entries. The main list shows
/// one row per window: the window entry until a script window proves it owns
/// that window, then the script window's active tab (its "promoted" tab). A
/// claimed window entry is kept as a shadow so its recency and state flow to
/// the tab rows and come back if the script window disappears.
///
/// A value type with explicit time: the owner decides the isolation, and
/// tests drive every path with fake snapshots and fixed instants.
public struct TabStore: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Consecutive sweeps a window must be absent from the WindowServer
        /// before it is removed (F). Three sweeps at the default 5s period
        /// outlast any Space or fullscreen transition.
        public var missingStrikeThreshold = 3
        /// Private and incognito tabs are dropped unless the user opts in (L16).
        public var includesPrivateTabs = false
        /// A window re-added within this long of a claim-based removal is a
        /// claim rule misfiring (E).
        public var flapWindow: Duration = .seconds(5)

        public init() {}
    }

    private struct ClaimRecord: Sendable {
        var entry: Entry
        let scriptWindow: WindowKey
        let rule: ClaimRule
        let claimedAt: ContinuousClock.Instant
        /// A release the caller asked for (the provider went away) is not a
        /// claim rule misfiring; a re-add after it is not a flap.
        var countsAsFlap = true
    }

    private struct PendingRemoval: Sendable {
        var reason: RemovalReason
        /// Whether the row was in the main list when the removal was queued;
        /// it keeps showing exactly as it did until the panel closes (H).
        let wasShown: Bool
    }

    private enum TabMatch {
        case same(EntryID)
        case moved(EntryID)
        case new
    }

    /// Every entry, including tabs that are not promoted and rows whose
    /// removal is deferred. `sorted(mode:)` is the main-list projection.
    public private(set) var entries: [EntryID: Entry] = [:]
    public var ignoreRules: IgnoreRules
    public var configuration: Configuration
    public private(set) var currentGeneration = FocusGeneration.initial
    public private(set) var isPanelVisible = false
    /// Windows re-added within `flapWindow` of a claim-based removal.
    public private(set) var flapCount = 0
    /// Title claims that disagreed with a caller-supplied resolution; neither
    /// was applied.
    public private(set) var claimConflictCount = 0
    public private(set) var droppedReadCount = 0

    /// Tab tokens per script window in provider order.
    private var tabOrder: [WindowKey: [String]] = [:]
    /// The tab that represents each script window in the main list.
    private var promoted: [WindowKey: EntryID] = [:]
    /// The token the last tab read marked active, per script window.
    private var activeTab: [WindowKey: String] = [:]
    /// The main-list rank of each script window's row. Inherited from the
    /// window entry it claimed so the row does not move when the claim lands.
    private var slotRank: [WindowKey: UInt64] = [:]
    /// Script window -> the window entry it claimed.
    private var owner: [WindowKey: EntryID] = [:]
    /// Window entries removed by a claim, kept as shadows.
    private var claimed: [EntryID: ClaimRecord] = [:]
    /// Shadows whose script window vanished; restored by the next window read
    /// that lists them.
    private var released: [EntryID: ClaimRecord] = [:]
    /// Window key -> script window, supplied by the caller's resolution cascade.
    private var resolutions: [WindowKey: WindowKey] = [:]
    private var pending: [EntryID: PendingRemoval] = [:]
    private struct ReadLane: Hashable { let app: AppKey; let kind: ReadKind }
    private var latestSequence: [ReadLane: UInt64] = [:]
    private var nextSequence: UInt64 = 1
    private var nextFocusTick: UInt64 = 1
    private var nextDiscoveryRank: UInt64 = 1
    private static let log = Log.make("store")

    public init(ignoreRules: IgnoreRules = IgnoreRules(), configuration: Configuration = Configuration()) {
        self.ignoreRules = ignoreRules
        self.configuration = configuration
    }

    // MARK: - Generation and stamps (A, B)

    public mutating func advanceGeneration(to generation: FocusGeneration) {
        currentGeneration = max(currentGeneration, generation)
    }

    /// Call before starting a read; hand the stamp back with the result.
    public mutating func beginRead(for app: AppInfo, kind: ReadKind) -> ReadStamp {
        let sequence = nextSequence
        nextSequence += 1
        latestSequence[ReadLane(app: app.key, kind: kind)] = sequence
        return ReadStamp(app: app.key, kind: kind, generation: currentGeneration, sequence: sequence)
    }

    private mutating func rejection(of stamp: ReadStamp, expecting kind: ReadKind) -> ReadDisposition? {
        precondition(stamp.kind == kind, "a \(stamp.kind) stamp was handed to a \(kind) apply")
        if stamp.generation != currentGeneration {
            droppedReadCount += 1
            let current = currentGeneration.raw
            Self.log.debug("dropped stale read app=\(String(describing: stamp.app), privacy: .public) generation=\(stamp.generation.raw, privacy: .public) current=\(current, privacy: .public)")
            return .staleGeneration
        }
        if let latest = latestSequence[ReadLane(app: stamp.app, kind: kind)], latest != stamp.sequence {
            droppedReadCount += 1
            Self.log.debug("dropped superseded read app=\(String(describing: stamp.app), privacy: .public)")
            return .superseded
        }
        return nil
    }

    // MARK: - Window reads (C, G)

    /// Applies one window read of `app`.
    ///
    /// An empty read is rejected outright (L5). A non-empty read removes the
    /// app's active-Space windows it does not list; windows on other Spaces
    /// are invisible to AX enumeration and are left to the sweep (G).
    public mutating func applyWindows(_ snapshots: [WindowSnapshot], for app: AppInfo, isHidden: Bool,
                                      bumpFocused: Bool = false, stamp: ReadStamp,
                                      now: ContinuousClock.Instant = .now) -> ApplyResult {
        if let rejected = rejection(of: stamp, expecting: .windows) { return .dropped(rejected) }
        let kept = snapshots.filter { !ignoreRules.ignores($0) }
        guard !kept.isEmpty else {
            Self.log.debug("empty window read rejected pid=\(app.pid, privacy: .public)")
            return .dropped(.rejectedEmpty)
        }

        var changed = false
        var seen: Set<EntryID> = []
        for snapshot in kept {
            let id = EntryID.window(snapshot.key)
            seen.insert(id)
            if var existing = entries[id] {
                var updated = Self.merge(snapshot, into: &existing, isHidden: isHidden)
                if existing.missingStrikes != 0 { existing.missingStrikes = 0 }
                entries[id] = existing
                if pending[id] != nil {
                    pending[id] = nil
                    updated = true
                }
                if updated { changed = true }
            } else if var record = claimed[id] {
                let updated = Self.merge(snapshot, into: &record.entry, isHidden: isHidden)
                record.entry.missingStrikes = 0
                claimed[id] = record
                if updated, mirror(record.scriptWindow, from: record.entry) { changed = true }
            } else {
                var entry = Entry(id: id, kind: .window, key: snapshot.key, app: snapshot.app,
                                  title: snapshot.title, isMinimized: snapshot.isMinimized,
                                  isOnActiveSpace: snapshot.isOnActiveSpace, isHidden: isHidden,
                                  discoveryRank: nextDiscoveryRank)
                if let record = released.removeValue(forKey: id) {
                    entry.focusTick = record.entry.focusTick
                    entry.discoveryRank = record.entry.discoveryRank
                    if record.countsAsFlap, now - record.claimedAt < configuration.flapWindow {
                        flapCount += 1
                        let window = String(describing: configuration.flapWindow)
                        Self.log.warning("fallback flap pid=\(app.pid, privacy: .public): window re-added within \(window, privacy: .public) of a claim-based removal; a claim rule is misfiring")
                    }
                } else {
                    nextDiscoveryRank += 1
                }
                entries[id] = entry
                changed = true
            }
            if bumpFocused, snapshot.isFocused, bump(windowID: id) { changed = true }
        }

        var keptOffSpace = 0
        for entry in entries.values where entry.kind == .window && entry.app.key == app.key && !seen.contains(entry.id) {
            guard entry.isOnActiveSpace else { keptOffSpace += 1; continue }
            if windowClosed(entry.id, reason: .windowClosed) { changed = true }
        }
        for (id, record) in claimed where record.entry.app.key == app.key && !seen.contains(id) {
            guard record.entry.isOnActiveSpace else { keptOffSpace += 1; continue }
            if windowClosed(id, reason: .windowClosed) { changed = true }
        }
        for (id, record) in released where record.entry.app.key == app.key && !seen.contains(id) && record.entry.isOnActiveSpace {
            released[id] = nil
        }
        if keptOffSpace > 0 {
            Self.log.debug("keeping \(keptOffSpace, privacy: .public) window(s) on inactive Spaces pid=\(app.pid, privacy: .public)")
        }

        let claims = runClaims(for: app, now: now)
        return ApplyResult(disposition: .applied, changed: changed || !claims.isEmpty, claims: claims, releasedWindows: [])
    }

    // MARK: - Tab reads (C, D, E)

    /// Applies one tab read of `app`. Tabs are grouped by `windowKey` into
    /// script windows; a script window the read no longer lists is closed,
    /// and its claimed window entry is released.
    public mutating func applyTabs(_ snapshots: [TabSnapshot], for app: AppInfo, stability: TokenStability,
                                   stamp: ReadStamp, now: ContinuousClock.Instant = .now) -> ApplyResult {
        if let rejected = rejection(of: stamp, expecting: .tabs) { return .dropped(rejected) }
        guard !snapshots.isEmpty, !ignoreRules.ignores(app: app) else {
            Self.log.debug("empty tab read rejected pid=\(app.pid, privacy: .public); keeping existing entries")
            return .dropped(.rejectedEmpty)
        }

        var windowsInRead: [WindowKey] = []
        var grouped: [WindowKey: [TabSnapshot]] = [:]
        for snapshot in snapshots where grouped[snapshot.windowKey] == nil {
            windowsInRead.append(snapshot.windowKey)
            grouped[snapshot.windowKey] = []
        }
        for snapshot in snapshots where configuration.includesPrivateTabs || !snapshot.isPrivate {
            grouped[snapshot.windowKey, default: []].append(snapshot)
        }

        var changed = false
        var releasedNow: [EntryID] = []
        for scriptWindow in scriptWindows(of: app) where grouped[scriptWindow] == nil {
            if removeScriptWindow(scriptWindow, reason: .windowClosed, released: &releasedNow) { changed = true }
        }
        for scriptWindow in windowsInRead {
            let tabs = grouped[scriptWindow] ?? []
            if tabs.isEmpty {
                if removeScriptWindow(scriptWindow, reason: .windowClosed, released: &releasedNow) { changed = true }
            } else if applyScriptWindow(scriptWindow, tabs: tabs, app: app, stability: stability) {
                changed = true
            }
        }

        let claims = runClaims(for: app, now: now)
        return ApplyResult(disposition: .applied, changed: changed || !claims.isEmpty, claims: claims,
                           releasedWindows: releasedNow)
    }

    private mutating func applyScriptWindow(_ scriptWindow: WindowKey, tabs: [TabSnapshot], app: AppInfo,
                                            stability: TokenStability) -> Bool {
        var changed = false
        let existing = entries.values.filter { $0.kind == .tab && $0.key == scriptWindow }
        if slotRank[scriptWindow] == nil {
            slotRank[scriptWindow] = nextDiscoveryRank
            nextDiscoveryRank += 1
        }
        let flags = ownerFlags(of: scriptWindow)

        // Re-keys are planned against the pre-read entries and applied
        // removals first: two tabs that swapped positions each take the
        // other's id, and applying them one at a time would overwrite the
        // first insertion with the second.
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var consumed: Set<EntryID> = []
        var removals: [EntryID] = []
        var inserts: [(EntryID, Entry)] = []
        var promotedMoves: [EntryID: EntryID] = [:]
        for (snapshot, match) in zip(tabs, Self.match(tabs, against: existing, stability: stability)) {
            let id = EntryID(key: scriptWindow, tabToken: snapshot.token)
            switch match {
            case .same(let oldID):
                consumed.insert(oldID)
                var entry = byID[oldID]!
                if entry.title != snapshot.title { entry.title = snapshot.title; changed = true }
                if entry.url != snapshot.url { entry.url = snapshot.url; changed = true }
                if entry.isPrivate != snapshot.isPrivate { entry.isPrivate = snapshot.isPrivate; changed = true }
                if entry.app != app { entry.app = app; changed = true }
                inserts.append((oldID, entry))
                if pending[oldID] != nil { pending[oldID] = nil; changed = true }
            case .moved(let oldID):
                consumed.insert(oldID)
                let old = byID[oldID]!
                removals.append(oldID)
                inserts.append((id, Entry(id: id, kind: .tab, key: scriptWindow, app: app, title: snapshot.title,
                                          url: snapshot.url, isMinimized: old.isMinimized,
                                          isOnActiveSpace: old.isOnActiveSpace, isHidden: old.isHidden,
                                          isPrivate: snapshot.isPrivate, focusTick: old.focusTick,
                                          discoveryRank: old.discoveryRank)))
                promotedMoves[oldID] = id
                changed = true
            case .new:
                inserts.append((id, Entry(id: id, kind: .tab, key: scriptWindow, app: app, title: snapshot.title,
                                          url: snapshot.url, isMinimized: flags?.isMinimized ?? false,
                                          isOnActiveSpace: flags?.isOnActiveSpace ?? true,
                                          isHidden: flags?.isHidden ?? false, isPrivate: snapshot.isPrivate,
                                          discoveryRank: nextDiscoveryRank)))
                nextDiscoveryRank += 1
                changed = true
            }
        }
        for entry in existing where !consumed.contains(entry.id) {
            if remove(entry.id, reason: .tabClosed) { changed = true }
        }
        for oldID in removals {
            entries[oldID] = nil
            pending[oldID] = nil
        }
        for (id, entry) in inserts {
            // A moved tab landing on the id of a closed one replaces its row
            // outright; a queued removal of that id would drop the mover.
            pending[id] = nil
            entries[id] = entry
        }
        if let current = promoted[scriptWindow], let moved = promotedMoves[current] { promoted[scriptWindow] = moved }
        tabOrder[scriptWindow] = tabs.map(\.token)

        let active = tabs.first(where: \.isActive) ?? tabs[0]
        activeTab[scriptWindow] = active.token
        if promote(EntryID(key: scriptWindow, tabToken: active.token), in: scriptWindow) { changed = true }
        return changed
    }

    /// Pairs the read's tabs with existing entries. Stable tokens are
    /// identity. Positional tokens (Safari's index, H11) shift when a tab is
    /// dragged, so an entry is matched by title first: same token and title,
    /// then the same title at another position (a move), then the same token
    /// with a new title (a navigation).
    private static func match(_ tabs: [TabSnapshot], against existing: [Entry],
                              stability: TokenStability) -> [TabMatch] {
        var byToken: [String: Entry] = [:]
        for entry in existing {
            if let token = entry.id.tabToken { byToken[token] = entry }
        }
        switch stability {
        case .stable:
            return tabs.map { byToken[$0.token].map { .same($0.id) } ?? .new }
        case .positional:
            var result = [TabMatch?](repeating: nil, count: tabs.count)
            for (i, tab) in tabs.enumerated() {
                if let entry = byToken[tab.token], entry.title == tab.title {
                    result[i] = .same(entry.id)
                    byToken[tab.token] = nil
                }
            }
            for (i, tab) in tabs.enumerated() where result[i] == nil {
                let candidates = byToken.values.filter {
                    $0.title == tab.title && ($0.url == nil || tab.url == nil || $0.url == tab.url)
                }
                if candidates.count == 1, let token = candidates[0].id.tabToken {
                    result[i] = .moved(candidates[0].id)
                    byToken[token] = nil
                }
            }
            for (i, tab) in tabs.enumerated() where result[i] == nil {
                if let entry = byToken[tab.token] {
                    result[i] = .same(entry.id)
                    byToken[tab.token] = nil
                }
            }
            return result.map { $0 ?? .new }
        }
    }

    /// Makes `id` the row that stands for `scriptWindow` in the main list. It
    /// takes over the row's rank and the best recency of what it replaces so
    /// switching tabs never moves the window's row. A row whose removal is
    /// deferred keeps standing for the window until the panel closes (H);
    /// `drop` promotes the active tab then.
    private mutating func promote(_ id: EntryID, in scriptWindow: WindowKey) -> Bool {
        guard var entry = entries[id], let rank = slotRank[scriptWindow] else { return false }
        let previous = promoted[scriptWindow]
        if let previous, previous != id, pending[previous] != nil { return false }
        var tick = entry.focusTick
        if let previous, let previousEntry = entries[previous] { tick = max(tick, previousEntry.focusTick) }
        if let windowID = owner[scriptWindow], let window = entries[windowID] ?? claimed[windowID]?.entry {
            tick = max(tick, window.focusTick)
        }
        guard previous != id || entry.focusTick != tick || entry.discoveryRank != rank else { return false }
        entry.focusTick = tick
        entry.discoveryRank = rank
        entries[id] = entry
        promoted[scriptWindow] = id
        return true
    }

    // MARK: - Claims (E)

    /// Records that the caller's resolution cascade mapped `window` to
    /// `scriptWindow` (rule 3 input).
    public mutating func resolve(window: WindowKey, toScriptWindow scriptWindow: WindowKey,
                                 now: ContinuousClock.Instant = .now) -> ApplyResult {
        resolutions[window] = scriptWindow
        let id = EntryID.window(window)
        if let record = claimed[id], record.scriptWindow != scriptWindow {
            claimConflictCount += 1
            Self.log.warning("resolution disagrees with an existing \(String(describing: record.rule), privacy: .public) claim")
        }
        guard let app = (entries[id] ?? claimed[id]?.entry)?.app else {
            return ApplyResult(disposition: .applied, changed: false, claims: [], releasedWindows: [])
        }
        let claims = runClaims(for: app, now: now)
        return ApplyResult(disposition: .applied, changed: !claims.isEmpty, claims: claims, releasedWindows: [])
    }

    /// Tries the three rules, in order, on every unclaimed window entry of
    /// `app`. Anything ambiguous is left alone. Title matches are settled for
    /// every window before elimination is considered, so a script window a
    /// title vouches for is never given away as "the only one left". Skipped
    /// while the panel is visible: a claim swaps one row for another, and
    /// rows must not change under the user's selection (H);
    /// `setPanelVisible(false)` runs it.
    private mutating func runClaims(for app: AppInfo, now: ContinuousClock.Instant) -> [Claim] {
        guard !isPanelVisible else { return [] }
        let candidates = entries.values
            .filter { $0.kind == .window && $0.app.key == app.key && pending[$0.id] == nil }
            .sorted { $0.discoveryRank < $1.discoveryRank }
        var unowned = scriptWindows(of: app).filter { owner[$0] == nil && promoted[$0] != nil }
        guard !candidates.isEmpty, !unowned.isEmpty else { return [] }
        unowned.sort { slotRank[$0] ?? 0 < slotRank[$1] ?? 0 }

        var matchesByWindow: [EntryID: [WindowKey]] = [:]
        var matchesByScript: [WindowKey: Int] = [:]
        for window in candidates {
            for scriptWindow in unowned {
                guard let promotedID = promoted[scriptWindow], let tab = entries[promotedID],
                      TitleCorroboration.corroborates(windowTitle: window.title, tabTitle: tab.title,
                                                      appName: window.app.localizedName)
                else { continue }
                matchesByWindow[window.id, default: []].append(scriptWindow)
                matchesByScript[scriptWindow, default: 0] += 1
            }
        }
        let blankWindows = candidates.filter {
            TitleCorroboration.normalize($0.title, appName: $0.app.localizedName).isEmpty
        }

        var claims: [Claim] = []
        var settled: Set<EntryID> = []
        func take(_ window: Entry, _ scriptWindow: WindowKey, _ rule: ClaimRule) {
            claim(window, by: scriptWindow, rule: rule, now: now)
            unowned.removeAll { $0 == scriptWindow }
            settled.insert(window.id)
            claims.append(Claim(window: window.id, scriptWindow: scriptWindow, rule: rule))
            Self.log.info("claim rule=\(String(describing: rule), privacy: .public) pid=\(app.pid, privacy: .public)")
        }

        for window in candidates {
            guard let matches = matchesByWindow[window.id], matches.count == 1,
                  matchesByScript[matches[0]] == 1, unowned.contains(matches[0]) else { continue }
            if let resolution = resolutions[window.key], resolution != matches[0] {
                claimConflictCount += 1
                settled.insert(window.id)
                Self.log.warning("title claim disagrees with resolution pid=\(app.pid, privacy: .public); leaving the window alone")
                continue
            }
            take(window, matches[0], .title)
        }
        for window in candidates where !settled.contains(window.id) {
            let resolution = resolutions[window.key]
            if blankWindows.count == 1, blankWindows[0].id == window.id, unowned.count == 1 {
                if let resolution, resolution != unowned[0] {
                    claimConflictCount += 1
                    Self.log.warning("elimination claim disagrees with resolution pid=\(app.pid, privacy: .public); leaving the window alone")
                    continue
                }
                take(window, unowned[0], .elimination)
            } else if let resolution, unowned.contains(resolution) {
                take(window, resolution, .resolution)
            }
        }
        return claims
    }

    /// The row keeps the earlier of the two discovery ranks: whichever side
    /// was seen first is where the user already saw this window.
    private mutating func claim(_ window: Entry, by scriptWindow: WindowKey, rule: ClaimRule,
                                now: ContinuousClock.Instant) {
        var window = window
        let rank = min(slotRank[scriptWindow] ?? window.discoveryRank, window.discoveryRank)
        window.discoveryRank = rank
        owner[scriptWindow] = window.id
        slotRank[scriptWindow] = rank
        claimed[window.id] = ClaimRecord(entry: window, scriptWindow: scriptWindow, rule: rule, claimedAt: now)
        released[window.id] = nil
        entries[window.id] = nil
        pending[window.id] = nil
        if let promotedID = promoted[scriptWindow] { _ = promote(promotedID, in: scriptWindow) }
        _ = mirror(scriptWindow, from: window)
    }

    // MARK: - Removal (F, H, I)

    /// Reconciles against the WindowServer and the process table (F).
    ///
    /// `liveWindowIDs` is every window id the WindowServer currently lists;
    /// pass `nil` when it could not be read. An empty set is treated the same
    /// way: a running session always has windows, so an empty table is a
    /// failed read, not evidence (L5). A window absent for
    /// `missingStrikeThreshold` consecutive sweeps is removed; one absence is
    /// transient. `runningApps` removes every entry of an app that is gone.
    public mutating func sweep(liveWindowIDs: Set<UInt32>?, runningApps: Set<AppKey>? = nil,
                               now: ContinuousClock.Instant = .now) -> Bool {
        var changed = false
        if let runningApps {
            var present = Set(entries.values.map(\.app.key))
            present.formUnion(claimed.values.map(\.entry.app.key))
            present.formUnion(released.values.map(\.entry.app.key))
            for key in present where !runningApps.contains(key) {
                Self.log.info("sweep: app gone \(String(describing: key), privacy: .public)")
                if removeApp(key) { changed = true }
            }
        }
        guard let live = liveWindowIDs, !live.isEmpty else { return changed }
        let threshold = configuration.missingStrikeThreshold

        for id in Array(entries.keys) {
            guard case .cg(let wid) = id.key, var entry = entries[id], entry.kind == .window else { continue }
            if live.contains(wid) {
                if entry.missingStrikes != 0 { entry.missingStrikes = 0; entries[id] = entry }
                continue
            }
            entry.missingStrikes += 1
            entries[id] = entry
            if entry.missingStrikes >= threshold, windowClosed(id, reason: .struck) { changed = true }
        }
        for id in Array(claimed.keys) {
            guard case .cg(let wid) = id.key, var record = claimed[id] else { continue }
            if live.contains(wid) {
                if record.entry.missingStrikes != 0 { record.entry.missingStrikes = 0; claimed[id] = record }
                continue
            }
            record.entry.missingStrikes += 1
            claimed[id] = record
            if record.entry.missingStrikes >= threshold, windowClosed(id, reason: .struck) { changed = true }
        }
        for id in Array(released.keys) {
            guard case .cg(let wid) = id.key, var record = released[id] else { continue }
            if live.contains(wid) {
                record.entry.missingStrikes = 0
                released[id] = record
                continue
            }
            record.entry.missingStrikes += 1
            released[id] = record.entry.missingStrikes >= threshold ? nil : record
        }
        return changed
    }

    @discardableResult
    public mutating func removeApp(_ key: AppKey) -> Bool {
        var changed = false
        for entry in entries.values where entry.app.key == key {
            if remove(entry.id, reason: .appGone) { changed = true }
        }
        for (id, record) in claimed where record.entry.app.key == key {
            claimed[id] = nil
            owner[record.scriptWindow] = nil
        }
        for (id, record) in released where record.entry.app.key == key {
            released[id] = nil
        }
        if case .bundle(let bundleID) = key {
            for scriptWindow in tabOrder.keys where Self.bundleID(of: scriptWindow) == bundleID {
                tabOrder[scriptWindow] = nil
                promoted[scriptWindow] = nil
                activeTab[scriptWindow] = nil
                slotRank[scriptWindow] = nil
                owner[scriptWindow] = nil
            }
            resolutions = resolutions.filter { Self.bundleID(of: $0.value) != bundleID }
        }
        return changed
    }

    /// Drops the app's tab entries only, releasing the windows they claimed.
    /// For a provider that became unavailable (permission revoked, browser
    /// not scriptable): the window entries return on the next window read.
    public mutating func removeTabs(for app: AppInfo) -> ApplyResult {
        var changed = false
        var releasedNow: [EntryID] = []
        for scriptWindow in scriptWindows(of: app) {
            if removeScriptWindow(scriptWindow, reason: .windowClosed, released: &releasedNow) { changed = true }
        }
        for id in releasedNow { released[id]?.countsAsFlap = false }
        return ApplyResult(disposition: .applied, changed: changed, claims: [], releasedWindows: releasedNow)
    }

    /// Activation doubles as a liveness probe (I): a failed activation is
    /// direct evidence, so the entry goes without strikes. Only report
    /// failures the provider is sure of; a timeout is unknown, not failure.
    @discardableResult
    public mutating func activationFailed(_ id: EntryID) -> Bool {
        let kind = String(describing: entries[id]?.kind)
        Self.log.info("removing entry after activation failure kind=\(kind, privacy: .public)")
        return remove(id, reason: .activationFailed)
    }

    /// Removals are queued while the panel is on screen and applied when it
    /// closes, so rows never disappear under the selection (H). Returns
    /// whether the list changed.
    @discardableResult
    public mutating func setPanelVisible(_ visible: Bool, now: ContinuousClock.Instant = .now) -> Bool {
        guard visible != isPanelVisible else { return false }
        isPanelVisible = visible
        guard !visible else { return false }
        var changed = false
        for id in Array(pending.keys) {
            drop(id)
            changed = true
        }
        var apps: [AppKey: AppInfo] = [:]
        for entry in entries.values where entry.kind == .window { apps[entry.app.key] = entry.app }
        for app in apps.values.sorted(by: { $0.pid < $1.pid }) where !runClaims(for: app, now: now).isEmpty {
            changed = true
        }
        return changed
    }

    public mutating func removeAll() {
        entries.removeAll()
        tabOrder.removeAll()
        promoted.removeAll()
        activeTab.removeAll()
        slotRank.removeAll()
        owner.removeAll()
        claimed.removeAll()
        released.removeAll()
        resolutions.removeAll()
        pending.removeAll()
    }

    /// Removes a window entry on direct evidence that the window is gone,
    /// along with the script window bound to it.
    private mutating func windowClosed(_ id: EntryID, reason: RemovalReason) -> Bool {
        var changed = false
        released[id] = nil
        resolutions[id.key] = nil
        if let record = claimed.removeValue(forKey: id) {
            owner[record.scriptWindow] = nil
            var ignored: [EntryID] = []
            if removeScriptWindow(record.scriptWindow, reason: reason, released: &ignored) { changed = true }
        }
        if entries[id] != nil, remove(id, reason: reason) { changed = true }
        return changed
    }

    /// Removes a script window's tabs. Its claimed window entry, if any, is
    /// released: it comes back when a window read lists it, not before, so a
    /// window that really closed is not resurrected.
    private mutating func removeScriptWindow(_ scriptWindow: WindowKey, reason: RemovalReason,
                                             released releasedNow: inout [EntryID]) -> Bool {
        var changed = false
        tabOrder[scriptWindow] = nil
        promoted[scriptWindow] = nil
        activeTab[scriptWindow] = nil
        slotRank[scriptWindow] = nil
        for entry in entries.values where entry.kind == .tab && entry.key == scriptWindow {
            if remove(entry.id, reason: reason) { changed = true }
        }
        if let windowID = owner.removeValue(forKey: scriptWindow), let record = claimed.removeValue(forKey: windowID) {
            released[windowID] = record
            releasedNow.append(windowID)
        }
        return changed
    }

    /// The single removal path. Returns whether the list changed now.
    private mutating func remove(_ id: EntryID, reason: RemovalReason) -> Bool {
        guard let entry = entries[id] else { return false }
        if isPanelVisible {
            if var existing = pending[id] {
                existing.reason = reason
                pending[id] = existing
            } else {
                pending[id] = PendingRemoval(reason: reason, wasShown: isShown(entry))
                Self.log.debug("deferred removal while switcher is visible reason=\(String(describing: reason), privacy: .public)")
            }
            return false
        }
        drop(id)
        return true
    }

    private mutating func drop(_ id: EntryID) {
        pending[id] = nil
        guard let entry = entries.removeValue(forKey: id) else { return }
        guard entry.kind == .tab, promoted[entry.key] == id else { return }
        // The row must outlive its active tab: the tab the last read marked
        // active stands in, else the first tab; the next read corrects it.
        promoted[entry.key] = nil
        var candidates = tabOrder[entry.key] ?? []
        if let active = activeTab[entry.key] { candidates.insert(active, at: 0) }
        if let token = candidates.first(where: { entries[EntryID(key: entry.key, tabToken: $0)] != nil }) {
            _ = promote(EntryID(key: entry.key, tabToken: token), in: entry.key)
        }
    }

    // MARK: - Focus and flags

    /// Marks `id` as most recently used. For a tab, its window's shadow moves
    /// with it so the recency survives a release.
    @discardableResult
    public mutating func bumpFocus(_ id: EntryID) -> Bool {
        if entries[id]?.kind == .window || claimed[id] != nil { return bump(windowID: id) }
        guard var entry = entries[id] else { return false }
        let tick = nextFocusTick
        nextFocusTick += 1
        entry.focusTick = tick
        entries[id] = entry
        if promoted[entry.key] == id, let windowID = owner[entry.key], var record = claimed[windowID] {
            record.entry.focusTick = tick
            claimed[windowID] = record
        }
        return true
    }

    private mutating func bump(windowID id: EntryID) -> Bool {
        let tick = nextFocusTick
        var changed = false
        if var entry = entries[id] {
            entry.focusTick = tick
            entries[id] = entry
            changed = true
        }
        if var record = claimed[id] {
            record.entry.focusTick = tick
            claimed[id] = record
            if let promotedID = promoted[record.scriptWindow], var tab = entries[promotedID] {
                tab.focusTick = tick
                entries[promotedID] = tab
                changed = true
            }
        }
        if changed { nextFocusTick += 1 }
        return changed
    }

    @discardableResult
    public mutating func setHidden(_ hidden: Bool, for key: AppKey) -> Bool {
        var changed = false
        for (id, entry) in entries where entry.app.key == key && entry.isHidden != hidden {
            var entry = entry
            entry.isHidden = hidden
            entries[id] = entry
            changed = true
        }
        for (id, record) in claimed where record.entry.app.key == key {
            var record = record
            record.entry.isHidden = hidden
            claimed[id] = record
        }
        for (id, record) in released where record.entry.app.key == key {
            var record = record
            record.entry.isHidden = hidden
            released[id] = record
        }
        return changed
    }

    /// Copies the window's state flags onto the tabs that stand for it.
    private mutating func mirror(_ scriptWindow: WindowKey, from window: Entry) -> Bool {
        var changed = false
        for token in tabOrder[scriptWindow] ?? [] {
            let id = EntryID(key: scriptWindow, tabToken: token)
            guard var tab = entries[id] else { continue }
            guard tab.isMinimized != window.isMinimized || tab.isOnActiveSpace != window.isOnActiveSpace
                    || tab.isHidden != window.isHidden else { continue }
            tab.isMinimized = window.isMinimized
            tab.isOnActiveSpace = window.isOnActiveSpace
            tab.isHidden = window.isHidden
            entries[id] = tab
            changed = true
        }
        return changed
    }

    private func ownerFlags(of scriptWindow: WindowKey) -> Entry? {
        guard let windowID = owner[scriptWindow] else { return nil }
        return entries[windowID] ?? claimed[windowID]?.entry
    }

    // MARK: - Queries

    public var isEmpty: Bool { entries.isEmpty }

    /// The main list: window entries plus one promoted tab per script window.
    public func sorted(mode: SortMode = .recency) -> [Entry] {
        EntrySort.sorted(entries.values.filter(isShown), mode: mode)
    }

    /// The tabs of a script window in provider order, for the detail pane.
    public func tabs(in scriptWindow: WindowKey) -> [Entry] {
        var result = (tabOrder[scriptWindow] ?? []).compactMap { entries[EntryID(key: scriptWindow, tabToken: $0)] }
        let listed = Set(result.map(\.id))
        let lingering = entries.values
            .filter { $0.kind == .tab && $0.key == scriptWindow && !listed.contains($0.id) }
            .sorted { $0.discoveryRank < $1.discoveryRank }
        result.append(contentsOf: lingering)
        return result
    }

    public func promotedTab(in scriptWindow: WindowKey) -> Entry? {
        promoted[scriptWindow].flatMap { entries[$0] }
    }

    /// The window entry a script window claimed; the key to raise before the
    /// provider selects the tab.
    public func claimedWindow(for scriptWindow: WindowKey) -> WindowKey? {
        owner[scriptWindow]?.key
    }

    public func scriptWindow(owning window: WindowKey) -> WindowKey? {
        claimed[.window(window)]?.scriptWindow
    }

    /// Window rows count 1 under their key; script windows count their tabs.
    /// App counts are main-list rows, one per window.
    public func groupCounts() -> GroupCounts {
        var byWindow: [WindowKey: Int] = [:]
        var byApp: [AppKey: Int] = [:]
        for entry in entries.values {
            let shown = isShown(entry)
            if entry.kind == .tab || shown { byWindow[entry.key, default: 0] += 1 }
            if shown { byApp[entry.app.key, default: 0] += 1 }
        }
        return GroupCounts(byWindowKey: byWindow, byAppKey: byApp)
    }

    private func isShown(_ entry: Entry) -> Bool {
        if let pending = pending[entry.id] { return pending.wasShown }
        return entry.kind == .window || promoted[entry.key] == entry.id
    }

    private func scriptWindows(of app: AppInfo) -> [WindowKey] {
        guard !app.bundleID.isEmpty else { return [] }
        return tabOrder.keys.filter { Self.bundleID(of: $0) == app.bundleID }
    }

    private static func bundleID(of key: WindowKey) -> String? {
        if case .scripted(let bundleID, _) = key { return bundleID }
        return nil
    }

    /// Returns `true` when a display-relevant field changed.
    private static func merge(_ snapshot: WindowSnapshot, into entry: inout Entry, isHidden: Bool) -> Bool {
        var changed = false
        if entry.title != snapshot.title { entry.title = snapshot.title; changed = true }
        if entry.app != snapshot.app { entry.app = snapshot.app; changed = true }
        if entry.isMinimized != snapshot.isMinimized { entry.isMinimized = snapshot.isMinimized; changed = true }
        if entry.isOnActiveSpace != snapshot.isOnActiveSpace { entry.isOnActiveSpace = snapshot.isOnActiveSpace; changed = true }
        if entry.isHidden != isHidden { entry.isHidden = isHidden; changed = true }
        return changed
    }
}

extension GroupCounts {
    init(byWindowKey: [WindowKey: Int], byAppKey: [AppKey: Int]) {
        self.byWindowKey = byWindowKey
        self.byAppKey = byAppKey
    }
}
