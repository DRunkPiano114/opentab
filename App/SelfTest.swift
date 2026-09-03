import AppKit
import ApplicationServices
import OpenTabAX
import OpenTabCore
import OpenTabScript
import OpenTabWS

/// `--selftest --out <dir>` diagnostic run. Results go to `<dir>/selftest.txt`
/// because an app launched through `open` has no stdout. No window titles are
/// written (L16).
@MainActor
enum SelfTest {
    static func outputDirectory(from arguments: [String]) -> URL? {
        guard arguments.contains("--selftest") else { return nil }
        if let i = arguments.firstIndex(of: "--out"), i + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    static func run(outputDirectory: URL) async {
        var lines: [String] = []
        let trusted = AXTrust.isTrusted
        lines.append("bundle=\(Bundle.main.bundleIdentifier ?? "nil") path=\(Bundle.main.bundlePath)")
        lines.append("axTrusted=\(trusted)")

        let source = AXWindowSource()
        lines.append("windowIDBridgeAvailable=\(source.isWindowIDBridgeAvailable)")

        let frontmostBefore = NSWorkspace.shared.frontmostApplication
        lines.append(contentsOf: measurePanel())
        lines.append(contentsOf: focusCheck(frontmostBefore: frontmostBefore, trusted: trusted))

        if trusted {
            let directory = WorkspaceAppDirectory()
            let apps = directory.runningApps()
            let report = await source.measure(apps: apps)
            lines.append(report.text)
            lines.append(contentsOf: await perAppSummary(apps: apps, source: source, directory: directory))
            lines.append(contentsOf: await accessibilityTabScan(apps: apps))
            if let bundleID = argument("--activate") {
                lines.append(contentsOf: await activationCheck(bundleID: bundleID, apps: apps, source: source))
            }
            lines.append(contentsOf: await coordinatorReport())
        } else {
            lines.append("enumeration skipped: Accessibility not granted (grant ~/Applications/OpenTab.app and rerun)")
        }

        let text = lines.joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: outputDirectory.appendingPathComponent("selftest.txt"), options: .atomic)
        } catch {
            Log.make("selftest").error("write failed: \(String(describing: error), privacy: .public)")
        }
        NSApp.terminate(nil)
    }

    /// Cold show (no pre-warm) versus a second show after the first has warmed
    /// SwiftUI's layout, then a pre-warmed controller, to reproduce the
    /// 43.6ms → 2.2ms measurement from the appendix.
    private static func measurePanel() -> [String] {
        let rows = PanelViewModel.Row.placeholders(count: 30)
        var lines: [String] = []

        let cold = PanelController(model: PanelViewModel())
        cold.show(rows: rows, selectedIndex: 1)
        lines.append("panelShowCold=\(format(cold.lastShowDuration))")
        cold.hide()
        cold.show(rows: rows, selectedIndex: 1)
        lines.append("panelShowSecond=\(format(cold.lastShowDuration))")
        cold.hide()

        let warmed = PanelController(model: PanelViewModel())
        warmed.prewarm()
        warmed.show(rows: rows, selectedIndex: 1)
        lines.append("panelShowPrewarmed=\(format(warmed.lastShowDuration))")
        lines.append("panelVisible=\(warmed.panel.isVisible) appActive=\(NSApp.isActive) panelIsKey=\(warmed.panel.isKeyWindow)")
        warmed.hide()
        return lines
    }

    /// The panel must not take focus (L2: judged by observable behaviour). With
    /// the grant, the previously frontmost app's own `kAXFrontmostAttribute` is
    /// the strongest available signal; without it only NSWorkspace is available.
    private static func focusCheck(frontmostBefore: NSRunningApplication?, trusted: Bool) -> [String] {
        var lines: [String] = []
        let after = NSWorkspace.shared.frontmostApplication
        lines.append("frontmostBefore=\(frontmostBefore?.bundleIdentifier ?? "nil") frontmostAfterPanel=\(after?.bundleIdentifier ?? "nil")")
        guard trusted, let before = frontmostBefore else { return lines }
        let element = AXUIElementCreateApplication(before.processIdentifier)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXFrontmostAttribute as CFString, &value)
        lines.append("previousAppAXFrontmost=\(String(describing: value as? Bool)) error=\(error.rawValue)")
        return lines
    }

    private static func argument(_ name: String) -> String? {
        let arguments = CommandLine.arguments
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    /// One line per app: counts and flags only, never titles (L16).
    private static func perAppSummary(apps: [AppInfo], source: AXWindowSource,
                                      directory: WorkspaceAppDirectory) async -> [String] {
        var lines = ["per app (bundle windows minimized hidden):"]
        for app in apps.sorted(by: { $0.bundleID < $1.bundleID }) {
            let deadline = ContinuousClock.now + .seconds(1)
            guard let windows = try? await source.snapshot(of: app, deadline: deadline), !windows.isEmpty else { continue }
            let minimized = windows.filter(\.isMinimized).count
            lines.append("  \(app.bundleID.isEmpty ? "pid\(app.pid)" : app.bundleID) \(windows.count) \(minimized) \(directory.isHidden(app))")
        }
        return lines
    }

    /// The Accessibility tab scan run against every running app: what it
    /// finds, how much tree it walks, and what it costs. Counts only, never a
    /// tab title (L16).
    ///
    /// This is also where the Chromium path is checked. The product reads
    /// Chromium tabs over AppleScript, which is the only route that can tell
    /// an incognito window apart (L16), so the scan itself is verified here
    /// rather than through the list.
    private static func accessibilityTabScan(apps: [AppInfo]) async -> [String] {
        let provider = AXTabProvider()
        guard provider.isAvailable else { return ["axTabs: unavailable, _AXUIElementGetWindow did not resolve"] }
        var lines = ["axTabs (bundle windows tabs titlesNonEmpty windowsNotExactlyOneActive nodes stops took):"]
        var totalNodes = 0
        var totalTabs = 0
        let started = ContinuousClock.now
        for app in apps.sorted(by: { $0.bundleID < $1.bundleID }) {
            guard let report = await provider.report(for: app, deadline: .now + .milliseconds(500)),
                  report.windowsScanned > 0 else { continue }
            totalNodes += report.nodesVisited
            totalTabs += report.tabsFound
            let name = report.bundleID.isEmpty ? "pid\(app.pid)" : report.bundleID
            lines.append("  \(name) \(report.windowsScanned) \(report.tabsFound) \(report.titlesNonEmpty) " +
                         "\(report.windowsWithoutOneActiveTab) \(report.nodesVisited) " +
                         "\(report.stops.isEmpty ? "-" : report.stops.joined(separator: ",")) \(format(report.duration))")
        }
        lines.append("  axTabs total tabs=\(totalTabs) nodes=\(totalNodes) serialWall=\(format(ContinuousClock.now - started))")
        return lines
    }

    /// `--activate <bundle id>`: raise that app's first listed window through
    /// the production activator and report the read-back verdict (L2).
    private static func activationCheck(bundleID: String, apps: [AppInfo], source: AXWindowSource) async -> [String] {
        guard let app = apps.first(where: { $0.bundleID == bundleID }) else {
            return ["activate \(bundleID): app not in candidate list"]
        }
        let deadline = ContinuousClock.now + .seconds(1)
        guard let windows = try? await source.snapshot(of: app, deadline: deadline), let target = windows.first else {
            return ["activate \(bundleID): no windows listed"]
        }
        let activator = AXWindowActivator(source: source)
        let started = ContinuousClock.now
        do {
            try await activator.activate(target.key, deadline: ContinuousClock.now + .milliseconds(800))
            return ["activate \(bundleID): confirmed in \(format(ContinuousClock.now - started)) key=\(target.key) wasMinimized=\(target.isMinimized)"]
        } catch {
            return ["activate \(bundleID): FAILED \(String(describing: error)) after \(format(ContinuousClock.now - started))"]
        }
    }

    /// The production stack (off-space source, providers, store) run through
    /// one full reconcile, then reported per app: rows versus windows, tabs
    /// per window, degraded state and the store's own diagnostics. Counts
    /// and keys only, never titles (L16). No consent prompt can appear here.
    ///
    /// `--stall <bundle id>` then stops that process with SIGSTOP, runs a
    /// second reconcile and times the panel against it (the G-3 wedged
    /// browser check); the process is continued before returning.
    /// `--activate-tab <bundle id>` selects a tab that is not active in that
    /// browser's first listed window, reads back where the browser landed,
    /// and puts the previously active tab back.
    private static func coordinatorReport() async -> [String] {
        let source = AXWindowSource()
        let offSpace = OffSpaceWindowSource(base: source)
        let engine = AppleScriptEngine()
        let gate = AutomationGateKeeper()
        let providers = TabProviderRegistry(engine: engine, includesPrivate: false)
        let coordinator = SwitcherCoordinator(source: offSpace, activator: OffSpaceWindowActivator(source: offSpace),
                                              directory: WorkspaceAppDirectory(), providers: providers,
                                              gate: gate, resolver: WindowResolver(directBridge: source.isWindowIDBridgeAvailable),
                                              windowServer: WindowServerIDs.current)
        let controller = PanelController(model: PanelViewModel())
        controller.prewarm()

        var lines: [String] = []
        let started = ContinuousClock.now
        await coordinator.refreshEverything(seedFocus: true)
        lines.append("coordinator: reconcile \(format(ContinuousClock.now - started))")
        lines.append(contentsOf: describe(coordinator, gate: gate))
        lines.append(panelTiming(controller, coordinator, label: "panelShowWithLiveRows"))

        if let bundleID = argument("--stall"), let app = coordinator.entries.first(where: { $0.app.bundleID == bundleID })?.app {
            kill(app.pid, SIGSTOP)
            defer { kill(app.pid, SIGCONT) }
            let stalled = ContinuousClock.now
            await coordinator.refreshEverything()
            lines.append("stalled \(bundleID): reconcile \(format(ContinuousClock.now - stalled))")
            lines.append(contentsOf: describe(coordinator, gate: gate, only: app.key))
            lines.append(panelTiming(controller, coordinator, label: "panelShowWhileStalled"))
        }

        lines.append(contentsOf: providerVerdicts(providers))
        lines.append(contentsOf: await faviconReport(coordinator))

        if let bundleID = argument("--activate-tab") {
            lines.append(contentsOf: await tabActivationCheck(bundleID: bundleID, coordinator: coordinator, providers: providers))
        }
        return lines
    }

    /// Which provider each running app gets, and whether it was judged a
    /// browser. Bundle ids and verdicts only, never a title (L16).
    private static func providerVerdicts(_ providers: TabProviderRegistry) -> [String] {
        var lines = ["tab providers (bundle isBrowser provider):"]
        for app in WorkspaceAppDirectory().runningApps().sorted(by: { $0.bundleID < $1.bundleID }) {
            let url = NSRunningApplication(processIdentifier: app.pid)?.bundleURL
            let kind = providers.provider(for: app).map { String(describing: type(of: $0)) } ?? "none"
            let name = app.bundleID.isEmpty ? "pid\(app.pid)" : app.bundleID
            lines.append("  \(name) \(TabProviderRegistry.isBrowser(app, appURL: url)) \(kind)")
        }
        return lines
    }

    /// The favicon tiers measured against the tabs the store actually holds,
    /// which is what the detail pane would ask for. Counts only: no host and
    /// no URL is written (L16). The remote tier stays off unless the user
    /// turned it on, so a run with it off measures the local caches alone.
    private static func faviconReport(_ coordinator: SwitcherCoordinator) async -> [String] {
        let urls = coordinator.store.entries.values.compactMap(\.url)
        let origins = Set(urls.compactMap { url in url.host().map { "\(url.scheme ?? "")://\($0)" } })
        let store = FaviconStore.shared
        var lines = ["favicons: tabsWithURL=\(urls.count) distinctOrigins=\(origins.count) " +
                     "remoteEnabled=\(store.isRemoteLookupEnabled) safariCache=\(store.hasSafariCacheAccess)"]
        guard !urls.isEmpty else { return lines }

        let signal = Signal()
        let started = ContinuousClock.now
        store.prefetch(urls) { signal.done = true }
        var waited = Duration.zero
        while !signal.done, waited < .seconds(10) {
            try? await Task.sleep(for: .milliseconds(50))
            waited += .milliseconds(50)
        }
        let stats = store.stats
        let resolved = stats.browserCache + stats.remote
        let asked = max(resolved + stats.missed, 1)
        lines.append("  browserCache=\(stats.browserCache) remote=\(stats.remote) missed=\(stats.missed) " +
                     "hitRate=\(String(format: "%.0f%%", Double(resolved) * 100 / Double(asked))) " +
                     "took=\(format(ContinuousClock.now - started))")
        return lines
    }

    @MainActor
    private final class Signal {
        var done = false
    }

    private static func describe(_ coordinator: SwitcherCoordinator, gate: AutomationGateKeeper,
                                 only: AppKey? = nil) -> [String] {
        let entries = coordinator.entries
        let counts = coordinator.groupCounts
        var lines = ["  rows=\(entries.count) store=\(coordinator.store.entries.count) " +
                     "flaps=\(coordinator.store.flapCount) claimConflicts=\(coordinator.store.claimConflictCount) " +
                     "droppedReads=\(coordinator.store.droppedReadCount) " +
                     "privateWindows=\(coordinator.store.privateWindowCount) " +
                     "privateUnplaced=\(coordinator.store.unattributedPrivateWindowCount) " +
                     "privateMisses=\(coordinator.store.privateAttributionMissCount) " +
                     "automationDenied=\(gate.deniedBundleIDs.sorted()) " +
                     "automationUnavailable=\(gate.unavailableBundleIDs.sorted())"]
        let byApp = Dictionary(grouping: entries, by: \.app.key)
        for (key, rows) in byApp.sorted(by: { String(describing: $0.key) < String(describing: $1.key) }) {
            if let only, key != only { continue }
            let windows = rows.filter { $0.kind == .window }.count
            let tabRows = rows.filter { $0.kind == .tab }
            let status = rows.map(coordinator.rowStatus).first.map { String(describing: $0) } ?? "?"
            var line = "  \(String(describing: key)) rows=\(rows.count) windowRows=\(windows) tabRows=\(tabRows.count) status=\(status)"
            if !tabRows.isEmpty {
                let perWindow = tabRows.map { counts.byWindowKey[$0.key] ?? 0 }
                line += " tabsPerWindow=\(perWindow) claimed=\(tabRows.filter { coordinator.store.claimedWindow(for: $0.key) != nil }.count)"
            }
            lines.append(line)
        }
        return lines
    }

    /// The panel path with the real list, timed the way the hotkey path is:
    /// rows from the store, then show.
    private static func panelTiming(_ controller: PanelController, _ coordinator: SwitcherCoordinator, label: String) -> String {
        let started = ContinuousClock.now
        let rows = PanelController.rows(for: coordinator.entries, counts: coordinator.groupCounts, status: coordinator.rowStatus)
        controller.show(rows: rows, selectedIndex: 1)
        let line = "\(label)=\(format(ContinuousClock.now - started)) rows=\(rows.count)"
        controller.hide()
        return line
    }

    private static func tabActivationCheck(bundleID: String, coordinator: SwitcherCoordinator,
                                           providers: TabProviderRegistry) async -> [String] {
        guard let row = coordinator.entries.first(where: { $0.app.bundleID == bundleID && $0.kind == .tab }),
              let provider = providers.provider(for: row.app) else {
            return ["activate-tab \(bundleID): no tab row listed"]
        }
        let tabs = coordinator.store.tabs(in: row.key)
        guard tabs.count > 1, let target = tabs.first(where: { $0.id != row.id }) else {
            return ["activate-tab \(bundleID): the first window has a single tab"]
        }
        func activeToken() async -> String? {
            let read = try? await provider.readTabs(for: row.app, deadline: .now + ScriptBudget.read)
            return read?.first { $0.windowKey == row.key && $0.isActive }?.token
        }
        var lines: [String] = []
        let started = ContinuousClock.now
        await coordinator.activate(target)
        let landed = await activeToken()
        lines.append("activate-tab \(bundleID): expected=\(target.id.tabToken ?? "?") landed=\(landed ?? "nil") ok=\(landed == target.id.tabToken) in \(format(ContinuousClock.now - started))")
        await coordinator.activate(row)
        lines.append("activate-tab \(bundleID): restored=\(await activeToken() == row.id.tabToken)")
        return lines
    }

    private static func format(_ duration: Duration?) -> String {
        guard let duration else { return "n/a" }
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.2fms", ms)
    }
}
