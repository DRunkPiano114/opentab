import ApplicationServices
import CoreGraphics
import Foundation
import OpenTabCore
import os

/// Marks a provider that reads over the Accessibility API instead of Apple
/// Events. Two things follow, and the coordinator relies on both.
///
/// It needs no Automation consent, so it must not go through the gate that
/// asks for it: sending a non-browser through that gate would ask the user to
/// authorise Apple Events for an app nothing ever scripts.
///
/// And its read names the windows it covered, which makes an empty read
/// evidence rather than silence. A script call that answers nothing may have
/// been refused, throttled or aimed at a browser that is still starting, so
/// `TabStore` keeps the rows it has. A scan that read a window to the end and
/// found no tab button is a different statement: that window has no tab
/// strip right now. Finder hides its tab bar the moment a window drops to one
/// tab, so without the distinction the last window to lose its tabs would
/// leave its rows behind for good.
public protocol AccessibilityTabReads {}

/// A window of a pid that `kAXWindows` omits (another Space, full screen), as
/// the off-Space window source lists it.
public struct OffSpaceWindow: @unchecked Sendable {
    public let windowID: CGWindowID
    /// `nil` when the source still lists the window but did not reach it this
    /// round.
    public let element: AXUIElement?

    public init(windowID: CGWindowID, element: AXUIElement?) {
        self.windowID = windowID
        self.element = element
    }
}

/// Answers from the off-Space source's last read without messaging the app.
public typealias OffSpaceWindowSupplier = @Sendable (pid_t) -> [OffSpaceWindow]

/// Reads tabs out of the Accessibility tree for apps no scripting dictionary
/// covers: Finder, Ghostty and other native tab groups.
///
/// One structural predicate (`AXSubrole == AXTabButton`) covers native AppKit
/// and Chromium alike, so there is no per-app role table. Every read runs on
/// the target pid's own serial queue, so an app that stops answering stalls
/// only its own scan, and every scan is bounded in depth, node count, fan-out
/// and wall-clock time.
public final class AXTabProvider: TabProvider, TabCloser, AccessibilityTabReads, @unchecked Sendable {
    /// Unused by the registry, which hands one instance to every eligible app;
    /// the protocol requires it.
    public let bundleIDs: [String] = []
    /// Accessibility exposes no tab identity: `AXIdentifier` is nil on both
    /// Finder's and Chrome's tab buttons, so a tab is its position and a
    /// dragged tab shifts it, exactly like Safari.
    public let tokenStability = TokenStability.positional

    /// Per-app tallies for the diagnostic self test. Counts only: a tab title
    /// never leaves this process.
    public struct ScanReport: Sendable {
        public var bundleID: String
        public var windowsScanned: Int
        /// Of `windowsScanned`, those only the off-Space source listed.
        public var windowsOffSpace: Int
        public var tabsFound: Int
        public var titlesNonEmpty: Int
        /// Windows whose tab strip did not report exactly one selected tab.
        public var windowsWithoutOneActiveTab: Int
        public var nodesVisited: Int
        /// Windows whose tabs came from a tab group's `AXTabs` rather than
        /// from the walk.
        public var windowsUsingDeclaredTabs: Int
        public var stops: [String]
        public var duration: Duration
    }

    private struct State {
        /// Tab elements of the last read, per window, indexed by token.
        var tabs: [CGWindowID: [AXElement]] = [:]
        var owners: [CGWindowID: pid_t] = [:]
        /// What the last scan of each pid reported per window.
        var emitted: [pid_t: [CGWindowID: [TabSnapshot]]] = [:]
    }

    private let limits = TabScanLimits()
    private let queues = PIDQueues()
    private let cgTable = CGWindowTable()
    private let tree = AXTabTreeSource()
    private let getWindow: AXGetWindowFunction?
    private let offSpaceWindows: OffSpaceWindowSupplier?
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let log = Log.make("ax.tabs")

    /// Without `offSpaceWindows` only the windows `kAXWindows` lists are
    /// scanned, so a tab group on another Space shows as a plain window row.
    public init(offSpaceWindows: OffSpaceWindowSupplier? = nil) {
        getWindow = PrivateSymbols.getWindow
        self.offSpaceWindows = offSpaceWindows
    }

    /// Whether tabs can be reported at all. Without the window-number bridge a
    /// scanned window cannot be named in the key space the store shares with
    /// the window rows, and unclaimable tab rows would be worse than none.
    public var isAvailable: Bool { getWindow != nil }

    // MARK: - TabProvider

    public func readTabs(for app: AppInfo, deadline: ContinuousClock.Instant) async throws -> [TabSnapshot] {
        try await readTabsWithCoverage(for: app, deadline: deadline).snapshots
    }

    /// Covers the windows the scan read to the end, those whose last tabs it
    /// repeated, and those the WindowServer no longer lists.
    public func readTabsWithCoverage(for app: AppInfo, deadline: ContinuousClock.Instant) async throws -> TabRead {
        guard isAvailable else { throw AXSourceError.notImplemented }
        return try await queues.perform(on: app.pid) {
            let scan = try self.scan(app: app, deadline: deadline)
            return TabRead(snapshots: scan.snapshots, coverage: .windows(Set(scan.covered.map { .cg($0) })))
        }
    }

    /// Selecting a tab is `AXPress` on the tab button itself; no scripting
    /// dictionary and no Apple Events consent are involved.
    public func activate(_ tab: TabSnapshot, deadline: ContinuousClock.Instant) async throws {
        try await perform(.press, on: tab, deadline: deadline)
    }

    /// A tab button's only child is its close button, in Finder and in
    /// Chromium alike. Pressing it closes the tab without selecting it first.
    public func close(_ tab: TabSnapshot, deadline: ContinuousClock.Instant) async throws {
        try await perform(.closeButton, on: tab, deadline: deadline)
    }

    // MARK: - Diagnostics

    /// One scan of every window of `app`, reported as counts. For the self
    /// test: it is the only place the Chromium path is exercised end to end,
    /// because the product reads Chromium tabs over AppleScript, which is the
    /// only route that can tell an incognito window apart.
    public func report(for app: AppInfo, deadline: ContinuousClock.Instant) async -> ScanReport? {
        guard isAvailable else { return nil }
        let clock = ContinuousClock()
        let started = clock.now
        let read = try? await queues.perform(on: app.pid) { try self.scan(app: app, deadline: deadline) }
        guard let read else { return nil }
        return ScanReport(bundleID: app.bundleID, windowsScanned: read.windowsScanned,
                          windowsOffSpace: read.windowsOffSpace, tabsFound: read.snapshots.count,
                          titlesNonEmpty: read.snapshots.count(where: { !$0.title.isEmpty }),
                          windowsWithoutOneActiveTab: read.windowsWithoutOneActiveTab,
                          nodesVisited: read.nodesVisited,
                          windowsUsingDeclaredTabs: read.windowsUsingDeclaredTabs,
                          stops: read.stops.sorted().map(\.rawValue),
                          duration: clock.now - started)
    }

    // MARK: - Scanning (runs on the pid's queue)

    private func scan(app: AppInfo, deadline: ContinuousClock.Instant) throws -> TabScanEngine<AXTabTreeSource>.Scan {
        try Self.checkDeadline(deadline)
        let appElement = AXElement.application(pid: app.pid)
        let windows = AXRead.value(appElement, kAXWindowsAttribute)
        let elements: [AXUIElement]
        switch windows.error {
        case .success:
            elements = (windows.value as? [AXUIElement]) ?? []
        case .noValue, .attributeUnsupported:
            elements = []
        default:
            throw AXSourceError.from(windows.error)
        }

        let pid = app.pid
        let offSpace = (offSpaceWindows?(pid) ?? []).map { ($0.windowID, $0.element.map(AXElement.init)) }
        let cached = state.withLock { $0.emitted[pid] ?? [:] }
        let engine = TabScanEngine(source: tree, limits: limits, isListable: Self.isListable,
                                   windowID: windowID(of:), layer: cgTable.layer(of:))
        let scan = try engine.scan(.init(axWindows: elements.map(AXElement.init), offSpace: offSpace,
                                         cached: cached),
                                   deadline: deadline)

        let replacement = scan.tabs
        state.withLock { state in
            // A window whose tabs the scan carried without reading keeps the
            // nodes of the read that found them.
            for (id, owner) in state.owners where owner == pid && scan.emitted[id] == nil {
                state.tabs[id] = nil
                state.owners[id] = nil
            }
            for (id, elements) in replacement {
                state.tabs[id] = elements
                state.owners[id] = pid
            }
            state.emitted[pid] = scan.emitted
        }
        log.debug("""
            ax tabs read pid=\(pid, privacy: .public) windows=\(scan.windowsScanned, privacy: .public) \
            offSpace=\(scan.windowsOffSpace, privacy: .public) reused=\(scan.reused.count, privacy: .public) \
            tabs=\(scan.snapshots.count, privacy: .public) nodes=\(scan.nodesVisited, privacy: .public)
            """)
        return scan
    }

    /// The same filter the window source applies, so a scanned window is
    /// always a window the list already has a row for: both subroles are kept
    /// and window state is never inferred from the subrole, and a record
    /// that is not a real window is dropped by its layer.
    private static func isListable(_ window: AXElement) -> Bool {
        guard let slots = AXRead.multiple(window, [kAXRoleAttribute, kAXSubroleAttribute]).values,
              (slots[0] as? String) == kAXWindowRole else { return false }
        let subrole = (slots[1] as? String) ?? ""
        return subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
    }

    private func windowID(of element: AXElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        guard getWindow(element.raw, &id) == .success, id != 0 else { return nil }
        return id
    }

    // MARK: - Acting on a tab

    private enum TabAction {
        case press
        case closeButton
    }

    private func perform(_ action: TabAction, on tab: TabSnapshot,
                         deadline: ContinuousClock.Instant) async throws {
        guard let id = Self.windowID(of: tab.windowKey), let index = Int(tab.token) else {
            throw AXActivationError.unknownWindow(tab.windowKey)
        }
        let found = state.withLock { state -> (element: AXElement, pid: pid_t)? in
            guard let elements = state.tabs[id], elements.indices.contains(index),
                  let pid = state.owners[id] else { return nil }
            return (elements[index], pid)
        }
        guard let found else { throw AXActivationError.unknownWindow(tab.windowKey) }
        try await queues.perform(on: found.pid) {
            try Self.checkDeadline(deadline)
            let target: AXElement
            switch action {
            case .press:
                target = found.element
            case .closeButton:
                guard let button = Self.closeButton(of: found.element) else {
                    throw AXSourceError.from(.actionUnsupported)
                }
                target = button
            }
            let error = AXUIElementPerformAction(target.raw, kAXPressAction as CFString)
            guard error == .success else { throw AXSourceError.from(error) }
        }
    }

    /// The single `AXButton` child a tab button carries.
    private static func closeButton(of tab: AXElement) -> AXElement? {
        guard let children = AXRead.value(tab, kAXChildrenAttribute).value as? [AXUIElement] else { return nil }
        for raw in children {
            let child = AXElement(raw)
            if (AXRead.value(child, kAXRoleAttribute).value as? String) == kAXButtonRole { return child }
        }
        return nil
    }

    /// The coordinator re-keys a provider's `.cg` window to the scripted form
    /// before it stores it, so an action arrives named either way.
    private static func windowID(of key: WindowKey) -> CGWindowID? {
        switch key {
        case .cg(let id): return id
        case .scripted(_, let token): return CGWindowID(token)
        case .ax: return nil
        }
    }

    private static func checkDeadline(_ deadline: ContinuousClock.Instant) throws {
        try TabScanEngine<AXTabTreeSource>.checkDeadline(deadline)
    }
}

/// The accessibility hierarchy as the scanner sees it. One batched read per
/// node: crossing the process boundary once for five attributes is about six
/// times cheaper than five crossings.
struct AXTabTreeSource: TabTreeSource {
    typealias Node = AXElement

    /// Positional. Slots 2 and 3 are display text for the empty-`AXTitle`
    /// fallback and are never branch inputs; slot 4 is read as a boolean only.
    private static let attributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
        kAXDescriptionAttribute, kAXValueAttribute,
    ]

    func attributes(of node: AXElement) -> TabNodeAttributes? {
        guard let slots = AXRead.multiple(node, Self.attributes).values,
              let role = slots[0] as? String else { return nil }
        return TabNodeAttributes(role: role,
                                 subrole: (slots[1] as? String) ?? "",
                                 title: (slots[2] as? String) ?? "",
                                 description: (slots[3] as? String) ?? "",
                                 isSelected: (slots[4] as? Bool) ?? false)
    }

    /// The range form of the children read transfers only what the limit
    /// allows, so a container with thousands of children costs the limit
    /// rather than the container.
    func children(of node: AXElement, limit: Int) -> [AXElement] {
        elements(of: node, attribute: kAXChildrenAttribute, limit: limit)
    }

    func declaredTabs(of node: AXElement, limit: Int) -> [AXElement] {
        elements(of: node, attribute: "AXTabs", limit: limit)
    }

    private func elements(of node: AXElement, attribute: String, limit: Int) -> [AXElement] {
        var out: CFArray?
        let error = AXUIElementCopyAttributeValues(node.raw, attribute as CFString,
                                                   0, CFIndex(limit), &out)
        guard error == .success || error == .noValue,
              let values = out as? [AXUIElement] else { return [] }
        return values.map(AXElement.init)
    }
}
