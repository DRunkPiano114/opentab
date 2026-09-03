import Foundation
import OpenTabAX
import OpenTabCore
import OpenTabScript
import os
@testable import OpenTab

/// Snapshots per app, mutable from tests, plus failure injection.
final class FakeWindowSource: WindowSource, @unchecked Sendable {
    private struct State {
        var windows: [AppKey: [WindowSnapshot]] = [:]
        var failing: [AppKey: AXSourceError] = [:]
        var reads: [AppKey: Int] = [:]
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func set(_ snapshots: [WindowSnapshot], for app: AppInfo) {
        lock.withLock { $0.windows[app.key] = snapshots }
    }

    func fail(_ app: AppInfo, with error: AXSourceError?) {
        lock.withLock { $0.failing[app.key] = error }
    }

    func reads(of app: AppInfo) -> Int { lock.withLock { $0.reads[app.key] ?? 0 } }

    func snapshot(of app: AppInfo, deadline: ContinuousClock.Instant) async throws -> [WindowSnapshot] {
        let (result, failure) = lock.withLock { state -> ([WindowSnapshot], AXSourceError?) in
            state.reads[app.key, default: 0] += 1
            return (state.windows[app.key] ?? [], state.failing[app.key])
        }
        if let failure { throw failure }
        return result
    }
}

final class FakeAppDirectory: AppDirectory, @unchecked Sendable {
    private struct State { var apps: [AppInfo] = []; var hidden: Set<AppKey> = []; var frontmost: AppInfo? }
    private let lock = OSAllocatedUnfairLock(initialState: State())

    func set(apps: [AppInfo]) { lock.withLock { $0.apps = apps } }
    func setFrontmost(_ app: AppInfo?) { lock.withLock { $0.frontmost = app } }

    func runningApps() -> [AppInfo] { lock.withLock { $0.apps } }
    func isHidden(_ app: AppInfo) -> Bool { lock.withLock { $0.hidden.contains(app.key) } }
    func frontmostApp() -> AppInfo? { lock.withLock { $0.frontmost } }
}

/// Records activations; throws whatever the test injects per key.
final class FakeActivator: WindowActivator, @unchecked Sendable {
    private struct State { var activated: [WindowKey] = []; var failures: [WindowKey: any Error] = [:] }
    private let lock = OSAllocatedUnfairLock(initialState: State())

    var activated: [WindowKey] { lock.withLock { $0.activated } }

    func fail(_ key: WindowKey, with error: any Error) {
        lock.withLock { $0.failures[key] = error }
    }

    func activate(_ key: WindowKey, deadline: ContinuousClock.Instant) async throws {
        let failure = lock.withLock { state -> (any Error)? in
            state.activated.append(key)
            return state.failures[key]
        }
        if let failure { throw failure }
    }
}

/// A scripted provider: the tabs it answers with, or the error it throws,
/// and a record of what it was asked to activate.
final class FakeTabProvider: TabProvider, @unchecked Sendable {
    private struct State {
        var tabs: [TabSnapshot] = []
        var readError: ScriptError?
        var activateError: ScriptError?
        var reads = 0
        var activated: [TabSnapshot] = []
        /// Applied to `tabs` after each activation, to script what the
        /// browser does in response.
        var onActivate: (@Sendable (TabSnapshot, inout [TabSnapshot]) -> Void)?
    }

    let bundleIDs: [String]
    let tokenStability: TokenStability
    private let lock = OSAllocatedUnfairLock(initialState: State())

    init(bundleIDs: [String], tokenStability: TokenStability = .stable) {
        self.bundleIDs = bundleIDs
        self.tokenStability = tokenStability
    }

    func set(tabs: [TabSnapshot]) { lock.withLock { $0.tabs = tabs } }
    func failReads(with error: ScriptError?) { lock.withLock { $0.readError = error } }
    func failActivation(with error: ScriptError?) { lock.withLock { $0.activateError = error } }
    func onActivate(_ body: @escaping @Sendable (TabSnapshot, inout [TabSnapshot]) -> Void) {
        lock.withLock { $0.onActivate = body }
    }

    var reads: Int { lock.withLock { $0.reads } }
    var activated: [TabSnapshot] { lock.withLock { $0.activated } }

    func readTabs(for app: AppInfo, deadline: ContinuousClock.Instant) async throws -> [TabSnapshot] {
        let (tabs, error) = lock.withLock { state -> ([TabSnapshot], ScriptError?) in
            state.reads += 1
            return (state.tabs, state.readError)
        }
        if let error { throw error }
        return tabs
    }

    func activate(_ tab: TabSnapshot, deadline: ContinuousClock.Instant) async throws {
        let error = lock.withLock { state -> ScriptError? in
            state.activated.append(tab)
            if let error = state.activateError { return error }
            state.onActivate?(tab, &state.tabs)
            return nil
        }
        if let error { throw error }
    }
}

@MainActor
final class FakeProviderLookup: TabProviderLookup {
    var providers: [String: any TabProvider] = [:]

    init(_ providers: [any TabProvider] = []) {
        for provider in providers {
            for bundleID in provider.bundleIDs { self.providers[bundleID] = provider }
        }
    }

    func provider(for app: AppInfo) -> (any TabProvider)? {
        providers[app.bundleID]
    }
}

@MainActor
final class FakeAutomationGate: AutomationGate {
    var allowed = true
    private(set) var deniedBundleIDs: Set<String> = []
    private(set) var checks = 0
    var onChange: (@MainActor () -> Void)?

    func mayReadTabs(of app: AppInfo) async -> Bool {
        checks += 1
        return allowed && !deniedBundleIDs.contains(app.bundleID)
    }

    func noteRefusal(of app: AppInfo) {
        deniedBundleIDs.insert(app.bundleID)
        onChange?()
    }
}

// MARK: - Fixtures

let chrome = AppInfo(bundleID: "com.google.Chrome", pid: 300, localizedName: "Google Chrome")
let safari = AppInfo(bundleID: "com.apple.Safari", pid: 400, localizedName: "Safari")
let notes = AppInfo(bundleID: "com.example.notes", pid: 500, localizedName: "Notes")

func chromeWindow(_ id: UInt32, _ page: String, focused: Bool = false) -> WindowSnapshot {
    WindowSnapshot(key: .cg(id), app: chrome, title: "\(page) - Google Chrome",
                   subrole: "AXStandardWindow", isMinimized: false, isFocused: focused)
}

func window(_ id: UInt32, _ app: AppInfo, title: String, focused: Bool = false) -> WindowSnapshot {
    WindowSnapshot(key: .cg(id), app: app, title: title, subrole: "AXStandardWindow",
                   isMinimized: false, isFocused: focused)
}

func chromeTab(_ window: String, _ token: String, _ title: String, active: Bool = false) -> TabSnapshot {
    TabSnapshot(windowKey: .scripted(bundleID: chrome.bundleID, token: window), token: token,
                title: title, url: URL(string: "https://example.test/\(token)"), isActive: active, isPrivate: false)
}

/// A tab keeps its URL when it moves, so the URL follows the title, not the index.
func safariTab(_ wid: UInt32, _ index: Int, _ title: String, active: Bool = false) -> TabSnapshot {
    let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
    return TabSnapshot(windowKey: .cg(wid), token: String(index), title: title,
                url: URL(string: "https://example.test/\(slug)"), isActive: active, isPrivate: false)
}

@MainActor
struct CoordinatorHarness {
    let source = FakeWindowSource()
    let directory = FakeAppDirectory()
    let activator = FakeActivator()
    let providers: FakeProviderLookup
    let gate = FakeAutomationGate()
    let coordinator: SwitcherCoordinator
    let windowServer: OSAllocatedUnfairLock<Set<UInt32>?>

    init(providers: [any TabProvider] = [], live: Set<UInt32>? = []) {
        self.providers = FakeProviderLookup(providers)
        let box = OSAllocatedUnfairLock<Set<UInt32>?>(initialState: live)
        windowServer = box
        coordinator = SwitcherCoordinator(source: source, activator: activator, directory: directory,
                                          providers: self.providers, gate: gate, resolver: nil,
                                          windowServer: { box.withLock { $0 } })
    }

    func setLive(_ ids: Set<UInt32>?) { windowServer.withLock { $0 = ids } }

    var entries: [Entry] { coordinator.entries }
    var rows: [PanelViewModel.Row] {
        PanelController.rows(for: entries, counts: coordinator.groupCounts, status: coordinator.rowStatus)
    }
}
