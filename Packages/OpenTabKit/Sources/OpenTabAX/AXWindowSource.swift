import ApplicationServices
import CoreGraphics
import Foundation
import OpenTabCore
import os

/// Enumerates windows over the Accessibility API, one app per call.
///
/// Reads run on the target pid's own serial queue (L13) and return value
/// types only; the elements stay behind the lock so the activator can find
/// them by `WindowKey`.
public final class AXWindowSource: WindowSource, @unchecked Sendable {
    struct CachedElement: Sendable {
        let pid: pid_t
        let element: AXElement
    }

    private struct State: Sendable {
        var elements: [WindowKey: CachedElement] = [:]
        var contactedPIDs: Set<pid_t> = []
    }

    struct ReadStats: Sendable {
        var raw = 0
        var kept = 0
        var minimized = 0
        var rejected: [String: Int] = [:]
        var subroles: [String: Int] = [:]

        mutating func reject(_ reason: String) { rejected[reason, default: 0] += 1 }
    }

    struct AppRead: Sendable {
        var snapshots: [WindowSnapshot]
        var stats: ReadStats
    }

    /// Positional. Slot 3 feeds only the L11 title fallback and is never a branch input.
    private static let windowAttributes: [String] = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXMinimizedAttribute]
    private static let measureBudget: Duration = .seconds(2)

    /// `false` when `_AXUIElementGetWindow` could not be resolved or was
    /// disabled with `OPENTAB_DISABLE_AXGETWINDOW=1`. Windows are then keyed
    /// by AX element and carry no level; the UI shows a degradation hint.
    public let isWindowIDBridgeAvailable: Bool

    private let getWindow: AXGetWindowFunction?
    private let queues = PIDQueues()
    private let cgTable = CGWindowTable()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let log = Log.make("ax")

    public convenience init() {
        let disabled = ProcessInfo.processInfo.environment["OPENTAB_DISABLE_AXGETWINDOW"] == "1"
        self.init(windowIDBridgeEnabled: !disabled)
    }

    public init(windowIDBridgeEnabled: Bool) {
        getWindow = windowIDBridgeEnabled ? PrivateSymbols.getWindow : nil
        isWindowIDBridgeAvailable = getWindow != nil
    }

    public func snapshot(of app: AppInfo, deadline: ContinuousClock.Instant) async throws -> [WindowSnapshot] {
        try await perform(on: app.pid) { try self.readWindows(of: app, deadline: deadline).snapshots }
    }

    /// Diagnostic sweep: a cold pass then a warm pass, parallel per pid.
    public func measure(apps: [AppInfo]) async -> EnumerationReport {
        let cold = await pass(apps)
        let warm = await pass(apps)

        var stats = ReadStats()
        for result in warm.results {
            if let read = result.read {
                stats.raw += read.stats.raw
                stats.kept += read.stats.kept
                stats.minimized += read.stats.minimized
                stats.rejected.merge(read.stats.rejected, uniquingKeysWith: +)
                stats.subroles.merge(read.stats.subroles, uniquingKeysWith: +)
            } else if let failure = result.failure {
                stats.reject("readFailed:\(failure)")
            }
        }
        let slowest = cold.results.sorted { $0.duration > $1.duration }.prefix(5)
            .map { (pid: $0.app.pid, bundleID: $0.app.bundleID, duration: $0.duration) }
        return EnumerationReport(coldDuration: cold.wall, warmDuration: warm.wall, appsAsked: apps.count,
                                 rawWindowCount: stats.raw, keptWindowCount: stats.kept,
                                 minimizedCount: stats.minimized, rejectedByReason: stats.rejected,
                                 subroleDistribution: stats.subroles, slowestApps: slowest)
    }

    // MARK: Module-internal support for the activator

    func perform<T: Sendable>(on pid: pid_t, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await queues.perform(on: pid, body)
    }

    func cachedElement(for key: WindowKey) -> CachedElement? {
        state.withLock { $0.elements[key] }
    }

    func windowID(of element: AXElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        guard getWindow(element.raw, &id) == .success, id != 0 else { return nil }
        return id
    }

    /// The app's `kAXFocusedWindowAttribute`, when readable.
    func focusedWindow(pid: pid_t) -> AXElement? {
        AXRead.element(AXRead.value(.application(pid: pid), kAXFocusedWindowAttribute).value)
    }

    /// The app's own `kAXFrontmostAttribute`: the window server's view of
    /// which app is active, unlike `NSWorkspace.frontmostApplication` (L2).
    func isFrontmost(pid: pid_t) -> Bool {
        (AXRead.value(.application(pid: pid), kAXFrontmostAttribute).value as? Bool) ?? false
    }

    static func checkDeadline(_ deadline: ContinuousClock.Instant) throws {
        if ContinuousClock.now >= deadline { throw AXSourceError.deadlineExceeded }
    }

    // MARK: Reading (runs on the pid's queue)

    private func readWindows(of app: AppInfo, deadline: ContinuousClock.Instant) throws -> AppRead {
        try Self.checkDeadline(deadline)
        let pid = app.pid
        let appElement = AXElement.application(pid: pid)

        let windows = AXRead.value(appElement, kAXWindowsAttribute)
        let elements: [AXUIElement]
        switch windows.error {
        case .success:
            elements = (windows.value as? [AXUIElement]) ?? []
        case .noValue, .attributeUnsupported:
            elements = []
        default:
            throw appFailure(windows.error, pid: pid)
        }
        // Deferred behind this read on the same serial queue: several apps
        // answer AXPreferredLanguage only after a full messaging timeout on
        // first contact, and a process that does not answer AX at all would
        // cost a second timeout. Neither belongs on the snapshot's critical path.
        if state.withLock({ $0.contactedPIDs.insert(pid).inserted }) {
            queues.queue(for: pid).async { self.logPreferredLanguage(of: app, element: appElement) }
        }
        let focused = AXRead.element(AXRead.value(appElement, kAXFocusedWindowAttribute).value)

        var stats = ReadStats()
        var snapshots: [WindowSnapshot] = []
        var kept: [WindowKey: CachedElement] = [:]

        for raw in elements {
            try Self.checkDeadline(deadline)
            stats.raw += 1
            let element = AXElement(raw)

            let read = AXRead.multiple(element, Self.windowAttributes)
            guard let slots = read.values else {
                switch read.error {
                case .cannotComplete, .apiDisabled, .notImplemented:
                    throw appFailure(read.error, pid: pid)
                default:
                    stats.reject("readFailed:\(axErrorName(read.error))")
                    continue
                }
            }

            guard (slots[0] as? String) == kAXWindowRole else {
                stats.reject("roleNotWindow")
                continue
            }
            let subrole = (slots[1] as? String) ?? ""
            stats.subroles[subrole.isEmpty ? "<none>" : subrole, default: 0] += 1
            guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else {
                stats.reject("subroleRejected:\(subrole.isEmpty ? "<none>" : subrole)")
                continue
            }

            let title = (slots[2] as? String) ?? ""
            let description = (slots[3] as? String) ?? ""
            let isMinimized = (slots[4] as? Bool) ?? false

            let key: WindowKey
            let level: Int32?
            if let id = windowID(of: element) {
                guard let layer = cgTable.layer(of: id) else {
                    stats.reject("notInCGWindowList")
                    continue
                }
                guard layer == 0 else {
                    stats.reject("levelNotZero")
                    continue
                }
                key = .cg(id)
                level = layer
            } else {
                key = .ax(pid: pid, elementID: element.stableID)
                level = nil
            }

            let isFocused = focused.map { $0 == element } ?? false
            snapshots.append(WindowSnapshot(key: key, app: app,
                                            title: title.isEmpty ? description : title,
                                            subrole: subrole, isMinimized: isMinimized,
                                            isOnActiveSpace: true, level: level, isFocused: isFocused))
            kept[key] = CachedElement(pid: pid, element: element)
            stats.kept += 1
            if isMinimized { stats.minimized += 1 }
        }

        let replacement = kept
        state.withLock { state in
            state.elements = state.elements.filter { $0.value.pid != pid }
            state.elements.merge(replacement) { _, new in new }
        }
        return AppRead(snapshots: snapshots, stats: stats)
    }

    /// Maps an app-level failure and forgets a pid whose process is gone.
    private func appFailure(_ error: AXError, pid: pid_t) -> AXSourceError {
        let mapped = AXSourceError.from(error)
        if mapped == .invalidElement {
            queues.forget(pid)
            state.withLock { state in
                state.elements = state.elements.filter { $0.value.pid != pid }
                state.contactedPIDs.remove(pid)
            }
        }
        return mapped
    }

    /// Records the target app's UI language once per pid, so localisation
    /// bugs can be traced to the language the app was actually running in.
    private func logPreferredLanguage(of app: AppInfo, element: AXElement) {
        let language = (AXRead.value(element, "AXPreferredLanguage").value as? String) ?? "?"
        log.debug("""
            first contact pid=\(app.pid, privacy: .public) \
            bundle=\(app.bundleID, privacy: .public) \
            language=\(language, privacy: .public)
            """)
    }

    // MARK: Measurement

    private struct PassResult: Sendable {
        let app: AppInfo
        let read: AppRead?
        let failure: String?
        let duration: Duration
    }

    private func pass(_ apps: [AppInfo]) async -> (results: [PassResult], wall: Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        let results = await withTaskGroup(of: PassResult.self, returning: [PassResult].self) { group in
            for app in apps {
                group.addTask {
                    let started = clock.now
                    let deadline = started + Self.measureBudget
                    do {
                        let read = try await self.perform(on: app.pid) {
                            try self.readWindows(of: app, deadline: deadline)
                        }
                        return PassResult(app: app, read: read, failure: nil, duration: clock.now - started)
                    } catch let error as AXSourceError {
                        return PassResult(app: app, read: nil, failure: error.name, duration: clock.now - started)
                    } catch {
                        return PassResult(app: app, read: nil, failure: "unknown", duration: clock.now - started)
                    }
                }
            }
            var collected: [PassResult] = []
            for await result in group { collected.append(result) }
            return collected
        }
        return (results, clock.now - start)
    }
}
