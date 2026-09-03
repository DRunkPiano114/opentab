import AppKit
import OpenTabAX
import OpenTabCore
import OpenTabScript
import OpenTabWS

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Log.make("app")

    private var model: PanelViewModel!
    private var panel: PanelController!
    private var hotKeys: HotKeyCenter!
    private var session: SwitcherSession!
    private var statusMenu: StatusMenuController!
    private var secureInput: SecureInputMonitor!
    private var source: AXWindowSource!
    private var directory: WorkspaceAppDirectory!
    private var coordinator: SwitcherCoordinator!
    private var trigger: AXRefreshTrigger!
    private var offSpace: OffSpaceSupport!
    private var engine: AppleScriptEngine!
    private var providers: TabProviderRegistry!
    private var automation: AutomationGateKeeper!
    private var systemEvents: SystemEventMonitor!
    private var accessibility: AccessibilityWatch!
    /// Whether the refresh machinery is running; it stops while the grant is
    /// missing and while another user's session is active.
    private var running = false
    /// The coordinator consumes the trigger's stream once for the process
    /// lifetime: cancelling that iteration would finish the stream, so a
    /// suspension only stops the trigger from producing.
    private var coordinatorStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app-hosted test bundle loads this binary as its host; the tests
        // drive the pieces they need themselves.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        if OffSpaceSupport.handleRestoreCommand(arguments: CommandLine.arguments) {
            NSApp.terminate(nil)
            return
        }

        AXConfiguration.configureGlobalTimeout()
        log.notice("""
            launched bundle=\(Bundle.main.bundleIdentifier ?? "nil", privacy: .public) \
            axTrusted=\(AXTrust.isTrusted, privacy: .public) \
            path=\(Bundle.main.bundlePath, privacy: .public)
            """)

        if let outDir = SelfTest.outputDirectory(from: CommandLine.arguments) {
            Task {
                await OffSpaceSupport.writeDiagnostics(to: outDir)
                await SelfTest.run(outputDirectory: outDir)
            }
            return
        }

        let defaults = UserDefaults.standard
        let rules = IgnoreRules(titlePatterns: defaults.stringArray(forKey: "ignoreTitlePatterns") ?? [])
        // `open` cannot pass environment variables, so the L10 degradation
        // path is reachable from the command line as well.
        source = AXWindowSource(windowIDBridgeEnabled: !CommandLine.arguments.contains("--disable-window-id-bridge"))
        // Off-space windows (remote tokens + CGS Space queries) and the
        // Cmd+Tab takeover sit on top of the pure-AX source; every missing
        // private symbol degrades back to it.
        offSpace = OffSpaceSupport(base: source)
        directory = WorkspaceAppDirectory(ignoreRules: rules)
        trigger = AXRefreshTrigger()

        // Private and incognito tabs stay out unless the user opts in (L16).
        let includesPrivate = defaults.bool(forKey: "tabs.includePrivate")
        var storeConfiguration = TabStore.Configuration()
        storeConfiguration.includesPrivateTabs = includesPrivate
        engine = AppleScriptEngine()
        providers = TabProviderRegistry(engine: engine, includesPrivate: includesPrivate)
        automation = AutomationGateKeeper()
        coordinator = SwitcherCoordinator(source: offSpace.windowSource, activator: offSpace.activator,
                                          directory: directory, providers: providers, gate: automation,
                                          resolver: WindowResolver(directBridge: source.isWindowIDBridgeAvailable),
                                          windowServer: WindowServerIDs.current, ignoreRules: rules,
                                          storeConfiguration: storeConfiguration)
        reportAutomationDefects()

        model = PanelViewModel()
        panel = PanelController(model: model)
        hotKeys = HotKeyCenter()
        session = SwitcherSession(coordinator: coordinator, panel: panel, hotKeys: hotKeys, model: model)
        session.frontmostApp = { Self.frontmostAppInfo() }
        automation.onChange = { [weak self] in self?.automationChanged() }
        automation.onAuthorized = { [weak self] app in
            guard let self else { return }
            Task { await self.coordinator.refresh(app: app) }
        }

        statusMenu = StatusMenuController()
        statusMenu.windowIDBridgeAvailable = source.isWindowIDBridgeAvailable
        statusMenu.onRebuildIndex = { [weak self] in
            guard let self else { return }
            Task { await self.coordinator.rebuild() }
        }
        statusMenu.onOpenAutomationSettings = { [weak self] in self?.automation.openSettings() }
        statusMenu.onEnableTabs = { [weak self] bundleID in self?.offerTabs(for: bundleID) }
        if !source.isWindowIDBridgeAvailable {
            log.error("_AXUIElementGetWindow unavailable: windows keyed by AX element only")
        }

        secureInput = SecureInputMonitor()
        secureInput.onChange = { [weak self] active in
            self?.statusMenu.secureInputActive = active
            self?.log.notice("secure input active=\(active, privacy: .public)")
        }
        secureInput.start()

        systemEvents = SystemEventMonitor()
        systemEvents.onWake = { [weak self] in self?.refreshEverything(reason: "wake") }
        systemEvents.onActiveSpaceChanged = { [weak self] in self?.refreshEverything(reason: "space") }
        systemEvents.onScreensChanged = { [weak self] in self?.session.screensChanged() }
        systemEvents.onSessionResigned = { [weak self] in self?.suspend(reason: "session resigned") }
        systemEvents.onSessionResumed = { [weak self] in self?.resume(reason: "session resumed") }
        systemEvents.start()

        panel.prewarm()
        session.start()
        offSpace.presentDegradationIfNeeded()
        // The system chords must be off before the app's own are bound (E2).
        if offSpace.enableCmdTabIfConfigured() {
            hotKeys.registerCommandTab()
        }

        accessibility = AccessibilityWatch()
        accessibility.onChange = { [weak self] trusted in
            if trusted {
                self?.accessibilityGranted()
            } else {
                self?.accessibilityRevoked()
            }
        }
        if !AXTrust.isTrusted {
            statusMenu.accessibilityGranted = false
            AXTrust.prompt()
        }
        accessibility.start()
    }

    /// A grant lands without a relaunch, and this also runs after one was
    /// revoked and restored: everything below is safe to start again.
    private func accessibilityGranted() {
        log.notice("accessibility granted")
        statusMenu.accessibilityGranted = true
        session.accessibilityGranted()
        resume(reason: "accessibility")
        IconCache.shared.prewarm(apps: directory.runningApps())
    }

    /// Packet §4: the list must not decay silently. The panel shows the
    /// onboarding message, the menu shows the marker, and refreshing stops
    /// until the grant is back.
    private func accessibilityRevoked() {
        log.error("accessibility not granted")
        statusMenu.accessibilityGranted = false
        session.accessibilityRevoked()
        suspend(reason: "accessibility")
    }

    private func resume(reason: String) {
        guard AXTrust.isTrusted, !running else { return }
        running = true
        log.notice("refresh started reason=\(reason, privacy: .public)")
        trigger.start()
        if !coordinatorStarted {
            coordinator.start(trigger: trigger)
            coordinatorStarted = true
        }
        let coordinator = coordinator!
        Task {
            await coordinator.refreshEverything(seedFocus: true)
            self.log.notice("initial index: \(coordinator.entries.count, privacy: .public) rows")
            await self.onboardAutomation()
        }
    }

    /// Packet §5: the Automation request is part of onboarding, made once
    /// for each browser running now that has never been asked about, one
    /// browser at a time, and never from a refresh. A browser that arrives
    /// later is offered from the status menu.
    private var onboarded = false
    private func onboardAutomation() async {
        guard !onboarded else { return }
        onboarded = true
        for app in directory.runningApps() where providers.provider(for: app) != nil {
            guard automation.awaitingRequest.contains(app.bundleID) || !automation.deniedBundleIDs.contains(app.bundleID) else { continue }
            await automation.requestThroughGuide(app)
        }
    }

    private func offerTabs(for bundleID: String) {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
        let app = AppInfo(bundleID: bundleID, pid: running.processIdentifier, localizedName: running.localizedName ?? bundleID)
        Task { await self.automation.requestThroughGuide(app) }
    }

    private func suspend(reason: String) {
        guard running else { return }
        running = false
        log.notice("refresh stopped reason=\(reason, privacy: .public)")
        trigger.stop()
    }

    /// Sleep/wake and Space changes invalidate the cache wholesale.
    private func refreshEverything(reason: String) {
        guard running else { return }
        log.notice("full refresh reason=\(reason, privacy: .public)")
        let coordinator = coordinator!
        Task { await coordinator.refreshEverything() }
    }

    private func automationChanged() {
        let awaiting = automation.awaitingRequest
        func name(_ bundleID: String) -> String {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
        }
        statusMenu.tabsUnavailable = automation.deniedBundleIDs.subtracting(awaiting).sorted().map(name)
        statusMenu.tabsAwaitingRequest = awaiting.sorted().map { (bundleID: $0, name: name($0)) }
    }

    /// A `-1743` can be our own bundle's fault; that is a ship-blocking bug,
    /// not a user decision, and it is logged as such at launch.
    private func reportAutomationDefects() {
        let defects = AutomationSelfCheck.defects(in: AutomationSelfCheck.currentBundleConfig())
        guard !defects.isEmpty else { return }
        let names = defects.map(\.rawValue).joined(separator: ",")
        log.fault("bundle cannot send Apple Events: \(names, privacy: .public)")
    }

    static func frontmostAppInfo() -> AppInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AppInfo(bundleID: app.bundleIdentifier ?? "", pid: app.processIdentifier,
                       localizedName: app.localizedName ?? "")
    }
}
