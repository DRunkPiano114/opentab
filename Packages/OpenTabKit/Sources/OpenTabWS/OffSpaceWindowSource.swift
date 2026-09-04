import CoreGraphics
import Foundation
import OpenTabAX
import OpenTabCore
import os

/// Which parts of the off-space path this system supports.
public struct OffSpaceAvailability: Sendable, Equatable {
    /// Remote-token symbols and `_AXUIElementGetWindow` all resolved.
    public let tokenPath: Bool
    /// The three CGS Space symbols resolved.
    public let spaceMap: Bool
    public let missingSymbols: [String]

    static func probe() -> OffSpaceAvailability {
        let missing = WSPrivateSymbols.availabilityTable.filter { !$0.resolved }.map(\.name)
        let tokenPath = [WSPrivateSymbols.Name.remoteTokenCreate, WSPrivateSymbols.Name.createWithRemoteToken,
                         WSPrivateSymbols.Name.getWindow].allSatisfy { !missing.contains($0) }
        let spaceMap = [WSPrivateSymbols.Name.mainConnectionID, WSPrivateSymbols.Name.copySpacesForWindows,
                        WSPrivateSymbols.Name.copyManagedDisplaySpaces].allSatisfy { !missing.contains($0) }
        return OffSpaceAvailability(tokenPath: tokenPath, spaceMap: spaceMap, missingSymbols: missing)
    }

    /// What the user is told when something is degraded; `nil` when nothing is.
    public var userVisibleSummary: String? {
        var lines: [String] = []
        if !tokenPath {
            lines.append("Windows on other Spaces and fullscreen windows will not be listed.")
        }
        if !spaceMap {
            lines.append("Which Space a window is on cannot be determined.")
        }
        guard !lines.isEmpty else { return nil }
        let symbols = missingSymbols.isEmpty ? "" : "\n\nMissing system symbols: " + missingSymbols.joined(separator: ", ")
        return lines.joined(separator: "\n") + symbols
    }
}

public struct OffSpaceConfiguration: Sendable, Equatable {
    public static let maxElementIDKey = "ws.scanMaxElementID"
    public static let budgetMillisecondsKey = "ws.scanBudgetMs"

    /// Exclusive upper bound of the element-id scan. The real ceiling is
    /// unknown: an app with very many elements may place a window above it,
    /// which is why a miss is never read as absence.
    public var maxElementID: UInt64 = 32_768
    /// Wall-clock budget of the scan within one snapshot.
    public var scanBudget: Duration = .milliseconds(200)
    /// How long a window a full cycle failed to reach is left alone. Rows on
    /// a Space with no element behind them (Chrome and WeChat keep several)
    /// cost a full cycle each time, 0.5-1.3s of IPC on that app's queue.
    public var exhaustedRetry: Duration = .seconds(300)
    /// A window whose CGS Space list is empty is either being moved between
    /// Spaces (a fullscreen transition takes about a second) or ordered out
    /// for good. A known window keeps its last snapshot for this long after
    /// it was last seen on a Space; beyond it, no Space means not a switch
    /// target.
    public var noSpaceGrace: Duration = .seconds(10)

    public init() {}

    /// `ws.scanMaxElementID` and `ws.scanBudgetMs` override the defaults, so
    /// the bound is adjustable without a rebuild.
    public static func from(_ defaults: UserDefaults) -> OffSpaceConfiguration {
        var configuration = OffSpaceConfiguration()
        let maxID = defaults.integer(forKey: maxElementIDKey)
        if maxID > 0 { configuration.maxElementID = UInt64(maxID) }
        let budget = defaults.integer(forKey: budgetMillisecondsKey)
        if budget > 0 { configuration.scanBudget = .milliseconds(budget) }
        return configuration
    }

    var scanner: ElementScanner.Configuration {
        var scanner = ElementScanner.Configuration()
        scanner.maxElementID = maxElementID
        scanner.budget = scanBudget
        scanner.exhaustedRetry = exhaustedRetry
        return scanner
    }
}

/// `WindowSource` over the pure-AX source that adds the windows AX
/// enumeration cannot see (other Spaces, fullscreen) through remote tokens, and
/// fills `isOnActiveSpace` from CGS Space membership.
///
/// Per app: the WindowServer's layer-0 windows minus the ones AX returned are
/// candidates; each is reached by a bounded, resumable element-id scan, then
/// read like any AX window. A window the scan did not reach this round keeps
/// its last snapshot as long as the WindowServer still lists it; it is
/// dropped only when the WindowServer no longer has it.
///
/// Every private symbol missing degrades to the pure-AX behaviour: the AX
/// result is passed through with `isOnActiveSpace == true`.
public final class OffSpaceWindowSource: WindowSource, @unchecked Sendable {
    /// Counts only, never titles.
    public struct AppReport: Sendable, Equatable {
        public var axWindows = 0
        public var layerZeroRows = 0
        public var candidates = 0
        public var reachedViaToken = 0
        public var keptUnreached = 0
        public var unreached = 0
        public var exhausted = 0
        public var probed = 0
        public var filtered = 0
        /// Layer-0 rows on no Space at all: ordered-out windows the app keeps
        /// around. Not scanned for (they are not switch targets) and not
        /// the minimized case (some minimized windows also report no Space,
        /// and AX lists those anyway).
        public var noSpace = 0
        /// Layer-0 rows on an active Space that are not on screen and that
        /// AX does not list: ordered out with a Space assignment left over.
        public var orderedOut = 0
        /// The WindowServer could not be read; nothing was pruned or scanned.
        public var windowListUnknown = false
    }

    private struct Reached: Sendable {
        let elementID: UInt64
        let element: RemoteElement
    }

    private struct Cached: Sendable {
        /// Stored with `isFocused == false`: a re-emitted snapshot must not
        /// claim focus over the window AX reports as focused now.
        var snapshot: WindowSnapshot
        /// When the window was last seen on a Space.
        var onSpaceAt: ContinuousClock.Instant
    }

    private struct PIDState: Sendable {
        var prefix: [UInt8]?
        var scan = ElementScanner.State()
        var reached: [CGWindowID: Reached] = [:]
        var lastSnapshot: [CGWindowID: Cached] = [:]
        var filtered: Set<CGWindowID> = []
        var lastReport = AppReport()
        var bundleID = ""
    }

    private struct State: Sendable {
        var pids: [pid_t: PIDState] = [:]
    }

    public let base: AXWindowSource
    public let availability: OffSpaceAvailability
    public let configuration: OffSpaceConfiguration

    private let backend: OffSpaceBackend?
    private let scanner: ElementScanner
    private let queues = SerialQueues()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let log = Log.make("ws")
    /// Injectable for the grace tests.
    var clock: @Sendable () -> ContinuousClock.Instant = { .now }

    public convenience init(base: AXWindowSource, configuration: OffSpaceConfiguration = OffSpaceConfiguration()) {
        let availability = OffSpaceAvailability.probe()
        let table = WindowServerTable()
        let spaceMap = availability.spaceMap ? SpaceMap() : nil
        let backend = availability.tokenPath ? OffSpaceBackend.live(table: table, spaceMap: spaceMap) : nil
        self.init(base: base, backend: backend, availability: availability, configuration: configuration)
    }

    init(base: AXWindowSource, backend: OffSpaceBackend?, availability: OffSpaceAvailability,
         configuration: OffSpaceConfiguration) {
        self.base = base
        self.backend = backend
        self.availability = availability
        self.configuration = configuration
        var scanner = ElementScanner()
        scanner.configuration = configuration.scanner
        self.scanner = scanner
    }

    /// The token path is in use: symbols resolved and the AX source keys
    /// windows by CGWindowID (without that there is nothing to subtract).
    public var isTokenPathActive: Bool {
        backend != nil && base.isWindowIDBridgeAvailable
    }

    public func snapshot(of app: AppInfo, deadline: ContinuousClock.Instant) async throws -> [WindowSnapshot] {
        let axSnapshots = try await base.snapshot(of: app, deadline: deadline)
        guard isTokenPathActive else { return axSnapshots }
        return try await queues.perform(on: app.pid) { self.augment(axSnapshots, of: app, deadline: deadline) }
    }

    /// Diagnostic read that ignores what AX enumerates and reaches every
    /// candidate through the token scan, so the two answers can be compared.
    /// Not for production refreshes: it discards the cheap path.
    public func snapshotViaTokenOnly(of app: AppInfo, deadline: ContinuousClock.Instant) async throws -> [WindowSnapshot] {
        guard isTokenPathActive else { throw AXSourceError.notImplemented }
        return try await queues.perform(on: app.pid) { self.augment([], of: app, deadline: deadline) }
    }

    public func report(for pid: pid_t) -> AppReport? {
        state.withLock { $0.pids[pid]?.lastReport }
    }

    /// Element ids that hits landed on, per pid, for the reach histogram.
    public func hitElementIDs() -> [(pid: pid_t, bundleID: String, elementIDs: [UInt64])] {
        state.withLock { state in
            state.pids.map { ($0.key, $0.value.bundleID, $0.value.scan.hits) }.sorted { $0.0 < $1.0 }
        }
    }

    // MARK: Module-internal support for the activator

    func reachedElement(for key: WindowKey) -> (pid: pid_t, element: RemoteElement)? {
        guard case .cg(let wid) = key else { return nil }
        return state.withLock { state in
            for (pid, pidState) in state.pids {
                if let reached = pidState.reached[wid] { return (pid, reached.element) }
            }
            return nil
        }
    }

    func perform<T: Sendable>(on pid: pid_t, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await queues.perform(on: pid, body)
    }

    // MARK: Merge (runs on the pid's queue)

    /// Adds the windows AX did not return and annotates Space membership.
    /// Never throws: a deadline that passes mid-scan ends the scan, and what
    /// was not reached keeps its last snapshot.
    func augment(_ axSnapshots: [WindowSnapshot], of app: AppInfo,
                 deadline: ContinuousClock.Instant) -> [WindowSnapshot] {
        guard let backend else { return axSnapshots }
        let pid = app.pid
        let now = clock()
        var pidState = state.withLock { $0.pids[pid] ?? PIDState() }
        pidState.bundleID = app.bundleID
        var report = AppReport()

        let axWindowIDs = Set(axSnapshots.compactMap { snapshot -> CGWindowID? in
            if case .cg(let id) = snapshot.key { return id }
            return nil
        })
        report.axWindows = axSnapshots.count
        var snapshots = axSnapshots
        var unresolved: Set<CGWindowID> = []
        var kept: Set<CGWindowID> = []
        let active = backend.activeSpaces()

        func finish() -> [WindowSnapshot] {
            snapshots = snapshots.map { snapshot in
                guard case .cg(let wid) = snapshot.key else { return snapshot }
                let spaces = backend.spacesOfWindow(wid)
                let onActive: Bool
                if let active {
                    onActive = SpaceMembership.isOnActiveSpace(windowSpaces: spaces, activeSpaces: active,
                                                               isMinimized: snapshot.isMinimized)
                } else {
                    onActive = axWindowIDs.contains(wid)
                }
                let annotated = WindowSnapshot(key: snapshot.key, app: snapshot.app, title: snapshot.title,
                                               subrole: snapshot.subrole, isMinimized: snapshot.isMinimized,
                                               isOnActiveSpace: onActive, level: snapshot.level,
                                               isFocused: snapshot.isFocused)
                let previous = pidState.lastSnapshot[wid]?.onSpaceAt
                let cached = WindowSnapshot(key: annotated.key, app: annotated.app, title: annotated.title,
                                            subrole: annotated.subrole, isMinimized: annotated.isMinimized,
                                            isOnActiveSpace: onActive, level: annotated.level, isFocused: false)
                pidState.lastSnapshot[wid] = Cached(snapshot: cached, onSpaceAt: spaces.isEmpty ? (previous ?? now) : now)
                return annotated
            }
            pidState.lastReport = report
            let finished = pidState
            state.withLock { $0.pids[pid] = finished }
            return snapshots
        }

        // No window list means no evidence at all: nothing is pruned, nothing
        // is scanned, and every window known from before stands in.
        guard let rows = backend.rows(pid) else {
            report.windowListUnknown = true
            for (wid, cached) in pidState.lastSnapshot where !axWindowIDs.contains(wid) {
                snapshots.append(cached.snapshot)
                report.keptUnreached += 1
            }
            log.notice("window list unavailable pid=\(pid, privacy: .public); kept \(report.keptUnreached, privacy: .public) cached")
            return finish()
        }
        let existing = Set(rows.map(\.id))

        // Direct evidence only: the WindowServer no longer lists the window.
        pidState.reached = pidState.reached.filter { existing.contains($0.key) }
        pidState.lastSnapshot = pidState.lastSnapshot.filter { existing.contains($0.key) }
        pidState.filtered.formIntersection(existing)
        for wid in axWindowIDs { pidState.reached.removeValue(forKey: wid) }

        var candidates = Set(rows.filter(WindowServerTable.isCandidate).map(\.id)).subtracting(axWindowIDs)
        if let active {
            for wid in candidates {
                let spaces = backend.spacesOfWindow(wid)
                if spaces.isEmpty {
                    candidates.remove(wid)
                    if let cached = pidState.lastSnapshot[wid], now - cached.onSpaceAt < configuration.noSpaceGrace {
                        kept.insert(wid)
                    } else {
                        pidState.lastSnapshot.removeValue(forKey: wid)
                        pidState.reached.removeValue(forKey: wid)
                        report.noSpace += 1
                    }
                } else if spaces.contains(where: { active.contains($0) }),
                          let row = rows.first(where: { $0.id == wid }), !row.isOnscreen {
                    // On the Space we are looking at, yet neither on screen nor
                    // listed by AX (which lists minimized windows): ordered out.
                    candidates.remove(wid)
                    pidState.lastSnapshot.removeValue(forKey: wid)
                    pidState.reached.removeValue(forKey: wid)
                    report.orderedOut += 1
                }
            }
        }
        report.layerZeroRows = rows.filter { $0.layer == 0 }.count
        report.candidates = candidates.count

        var focused: CGWindowID?? = nil
        func focusedWindowID() -> CGWindowID? {
            if let focused { return focused }
            let value = backend.focusedWindowID(pid)
            focused = .some(value)
            return value
        }
        func take(_ element: RemoteElement, wid: CGWindowID) -> Bool {
            switch backend.read(element) {
            case .window(let subrole, let title, let isMinimized):
                snapshots.append(WindowSnapshot(key: .cg(wid), app: app, title: title, subrole: subrole,
                                                isMinimized: isMinimized, isOnActiveSpace: false, level: 0,
                                                isFocused: focusedWindowID() == wid))
                return true
            case .notListable(let reason):
                pidState.filtered.insert(wid)
                pidState.reached.removeValue(forKey: wid)
                report.filtered += 1
                log.debug("token window not listable pid=\(pid, privacy: .public) wid=\(wid, privacy: .public) \(reason, privacy: .public)")
                return true
            case .unreadable:
                return false
            }
        }

        for wid in candidates where !pidState.filtered.contains(wid) {
            // Two IPCs per reached window; a wedged app pays the messaging
            // timeout for each, so the deadline is honoured between windows.
            guard ContinuousClock.now < deadline else {
                unresolved.insert(wid)
                continue
            }
            if let reached = pidState.reached[wid], backend.verify(reached.element, wid), take(reached.element, wid: wid) {
                report.reachedViaToken += 1
                continue
            }
            pidState.reached.removeValue(forKey: wid)
            unresolved.insert(wid)
        }

        if !unresolved.isEmpty {
            let prefix = pidState.prefix ?? backend.prefix(pid)
            pidState.prefix = prefix
            let started = ContinuousClock.now
            let outcome = scanner.scan(wanted: unresolved, state: &pidState.scan, deadline: deadline,
                                       probe: backend.probe(prefix))
            report.probed = outcome.probed
            report.exhausted = outcome.exhausted.count
            for (wid, elementID) in outcome.found {
                guard let element = backend.makeElement(prefix, elementID) else { continue }
                pidState.reached[wid] = Reached(elementID: elementID, element: element)
                if take(element, wid: wid) {
                    unresolved.remove(wid)
                    report.reachedViaToken += 1
                }
                log.notice("""
                    token hit pid=\(pid, privacy: .public) bundle=\(app.bundleID, privacy: .public) \
                    wid=\(wid, privacy: .public) elementID=\(elementID, privacy: .public) \
                    scanProbed=\(outcome.probed, privacy: .public) \
                    scanMs=\(Self.milliseconds(started.duration(to: .now)), format: .fixed(precision: 1), privacy: .public)
                    """)
            }
            if outcome.stop == .budget || outcome.stop == .exhausted {
                let line = """
                    token scan pid=\(pid) bundle=\(app.bundleID) stop=\(String(describing: outcome.stop)) \
                    probed=\(outcome.probed) cursor=\(pidState.scan.cursor) \
                    maxID=\(scanner.configuration.maxElementID) pending=\(unresolved.count) \
                    exhausted=\(outcome.exhausted.count)
                    """
                if outcome.stop == .exhausted {
                    log.notice("\(line, privacy: .public)")
                } else {
                    log.debug("\(line, privacy: .public)")
                }
            }
        }

        // A miss says nothing about the window. While the WindowServer
        // lists it, the last snapshot stands in.
        for wid in unresolved {
            if pidState.lastSnapshot[wid] != nil {
                kept.insert(wid)
            } else {
                report.unreached += 1
            }
        }
        for wid in kept {
            guard let cached = pidState.lastSnapshot[wid] else { continue }
            snapshots.append(cached.snapshot)
            report.keptUnreached += 1
        }
        return finish()
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
