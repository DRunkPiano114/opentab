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
    private var settings: SettingsStore!
    private var settingsModel: SettingsModel!
    private var settingsWindow: SettingsWindowController!
    private var onboarding: OnboardingWindowController?
    private var health: HealthMonitor!
    private var instances: InstanceWatch!
    /// Nil in a build whose bundle carries no update feed.
    private var updates: UpdateController?
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

        instances = InstanceWatch()
        instances.onChange = { [weak self] others in self?.otherInstancesChanged(others) }
        instances.start()

        if let outDir = SelfTest.outputDirectory(from: CommandLine.arguments) {
            Task {
                await OffSpaceSupport.writeDiagnostics(to: outDir)
                await SelfTest.run(outputDirectory: outDir)
            }
            return
        }

        // Before the first-run flow and before anything can ask for a
        // permission: a grant follows the app's location, so the app has to be
        // where it is going to stay before it is given one.
        if InstallLocationPrompt.runIfNeeded() { return }

        // After the relaunch prompt, so a copy about to move itself never
        // schedules a check, and after the test-host return above, so the
        // app-hosted suite never starts an updater.
        updates = UpdateController()

        settings = SettingsStore()
        settingsModel = SettingsModel()
        health = HealthMonitor()
        Theme.apply(Theme.Style(textScale: settings.textSize.scale, isWide: settings.widePanel))
        let rules = IgnoreRules(titlePatterns: settings.ignoreTitlePatterns)
        // A launch flag rather than an environment variable, because `open`
        // cannot pass one: this is how the fallback taken when the private
        // window-id symbol is missing gets exercised deliberately.
        source = AXWindowSource(windowIDBridgeEnabled: !CommandLine.arguments.contains("--disable-window-id-bridge"))
        // Off-space windows (remote tokens + CGS Space queries) and the
        // Cmd+Tab takeover sit on top of the pure-AX source; every missing
        // private symbol degrades back to it.
        offSpace = OffSpaceSupport(base: source)
        directory = WorkspaceAppDirectory(ignoreRules: rules)
        trigger = AXRefreshTrigger()

        // Private and incognito tab titles are fully readable through the
        // Accessibility API, so they are excluded until the user opts in.
        let includesPrivate = settings.includesPrivateTabs
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

        coordinator.sortMode = settings.sortMode

        model = PanelViewModel()
        panel = PanelController(model: model)
        panel.screenPosition = settings.panelPosition
        hotKeys = HotKeyCenter()
        hotKeys.configure(main: settings.mainHotKey, reverse: settings.reverseHotKey,
                          search: settings.searchHotKey)
        session = SwitcherSession(coordinator: coordinator, panel: panel, hotKeys: hotKeys, model: model)
        session.frontmostApp = { Self.frontmostAppInfo() }
        automation.onChange = { [weak self] in self?.automationChanged() }
        automation.onAuthorized = { [weak self] app in
            guard let self else { return }
            Task { await self.coordinator.refresh(app: app) }
        }

        statusMenu = StatusMenuController()
        statusMenu.updatesAvailable = updates != nil
        statusMenu.onCheckForUpdates = { [weak self] in self?.updates?.checkForUpdates() }
        // Assigning the closure replays the current value, so the menu is
        // right from the first draw.
        updates?.onCanCheckForUpdatesChanged = { [weak self] can in self?.statusMenu.canCheckForUpdates = can }
        statusMenu.isIconVisible = settings.showMenuBarIcon
        statusMenu.windowIDBridgeAvailable = source.isWindowIDBridgeAvailable
        statusMenu.onOpenSettings = { [weak self] in self?.showSettings() }
        statusMenu.onRebuildIndex = { [weak self] in
            guard let self else { return }
            Task { await self.coordinator.rebuild() }
        }
        statusMenu.onOpenAutomationSettings = { [weak self] in self?.automation.openSettings() }
        statusMenu.onEnableTabs = { [weak self] bundleID in self?.offerTabs(for: bundleID) }
        statusMenu.faviconRemoteDisclosure = FaviconStore.remoteDisclosureText
        statusMenu.faviconRemoteEnabled = FaviconStore.shared.isRemoteLookupEnabled
        statusMenu.safariCacheGranted = FaviconStore.shared.hasSafariCacheAccess
        // Through the store, so the menu item and the settings window cannot
        // end up showing different answers.
        statusMenu.onToggleFaviconRemote = { [weak self] enabled in
            self?.settings.remoteFavicons = enabled
        }
        statusMenu.onGrantSafariCache = { [weak self] in
            // The open panel is modal and an accessory app is not active when
            // its status item is clicked.
            NSApp.activate()
            let granted = FaviconStore.shared.requestSafariCacheAccess()
            self?.statusMenu.safariCacheGranted = granted
            self?.settingsModel.safariCacheGranted = granted
        }
        if !source.isWindowIDBridgeAvailable {
            log.error("_AXUIElementGetWindow unavailable: windows keyed by AX element only")
        }

        secureInput = SecureInputMonitor()
        secureInput.onChange = { [weak self] active in
            self?.statusMenu.secureInputActive = active
            self?.settingsModel.secureInputActive = active
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
        // Registering Cmd+Tab while the system still owns it succeeds and
        // then never delivers an event, so the takeover goes first.
        if offSpace.enableCmdTabIfConfigured() {
            hotKeys.registerCommandTab()
        }

        settingsModel.windowIDBridgeAvailable = source.isWindowIDBridgeAvailable
        settingsModel.cmdTabTakeoverAvailable = CmdTabTakeover.isAvailable
        settingsModel.safariCacheGranted = FaviconStore.shared.hasSafariCacheAccess
        // The scan at the top ran before there was a settings window to show
        // its verdict in, and before the copy running now was the one staying.
        announcesOtherInstances = true
        otherInstancesChanged(instances.others)
        settingsWindow = SettingsWindowController(store: settings, model: settingsModel, actions: settingsActions())
        settings.onChange = { [weak self] setting in self?.apply(setting) }
        let coordinatorForHealth = coordinator!
        health.entryCount = { coordinatorForHealth.entries.count }
        health.start()

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
            settingsModel.accessibilityGranted = false
            // The first-run flow owns the prompt when it is going to run, so
            // the system dialog never lands before the explanation.
            if settings.hasCompletedOnboarding { AXTrust.prompt() }
        }
        accessibility.start()
        startOnboardingIfNeeded()
    }

    /// The status item is the only way in, so hiding it has to leave one:
    /// launching OpenTab again reopens the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // The first-run window is already the thing in front; it must not get
        // the settings window stacked on top of it.
        if onboarding == nil { showSettings() }
        return true
    }

    /// A grant lands without a relaunch, and this also runs after one was
    /// revoked and restored: everything below is safe to start again.
    private func accessibilityGranted() {
        log.notice("accessibility granted")
        statusMenu.accessibilityGranted = true
        settingsModel.accessibilityGranted = true
        onboarding?.accessibilityChanged(true)
        session.accessibilityGranted()
        resume(reason: "accessibility")
        IconCache.shared.prewarm(apps: directory.runningApps())
    }

    /// The list must not decay silently. The panel shows the
    /// onboarding message, the menu shows the marker, and refreshing stops
    /// until the grant is back.
    private func accessibilityRevoked() {
        log.error("accessibility not granted")
        statusMenu.accessibilityGranted = false
        settingsModel.accessibilityGranted = false
        onboarding?.accessibilityChanged(false)
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

    /// The Automation request is part of onboarding, made once
    /// for each browser running now that has never been asked about, one
    /// browser at a time, and never from a refresh. A browser that arrives
    /// later is offered from the status menu.
    private var onboarded = false
    private func onboardAutomation() async {
        guard !onboarded, onboarding == nil else { return }
        onboarded = true
        for app in directory.runningApps() where providers.usesAppleEvents(for: app) {
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
        settingsModel.tabsUnavailable = statusMenu.tabsUnavailable
        settingsModel.tabsAwaitingRequest = statusMenu.tabsAwaitingRequest
    }

    private var otherInstances: [InstanceWatch.OtherInstance] = []
    /// Nothing is said about another copy until launch has committed to this
    /// process. The diagnostic run and the install-location flow both stop
    /// short of that point, and the latter starts the very copy that would
    /// otherwise be reported.
    private var announcesOtherInstances = false
    private var warnedAboutOtherInstance = false

    /// Both copies register the shortcut successfully and both receive every
    /// press of it, so two panels open at once. Which copy should go is the
    /// user's call — running two of them on purpose is a legitimate thing to
    /// be doing — so this only says what is happening.
    private func otherInstancesChanged(_ others: [InstanceWatch.OtherInstance]) {
        otherInstances = others
        guard announcesOtherInstances else { return }
        guard let other = others.first else {
            settingsModel.otherInstance = nil
            return
        }
        let location = other.path ?? "an unknown location"
        let headline = "Another copy of OpenTab is running from \(location)."
        let detail = """
            Both copies answer \(settings.mainHotKey.displayString), so every press opens two \
            switchers. Quit one of them.
            """
        settingsModel.otherInstance = "\(headline) \(detail)"
        guard !warnedAboutOtherInstance else { return }
        warnedAboutOtherInstance = true
        // A run loop block rather than a `Task`, and deliberately not run
        // from inside launch: `runModal` spins a nested run loop, during which
        // the main queue is not drained, so a modal entered from a main-actor
        // job holds every other one — the rescan that takes this warning back
        // down included — until the alert is answered, which may be hours.
        RunLoop.main.perform {
            // The main run loop runs its blocks on the main thread.
            MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.messageText = headline
                alert.informativeText = detail
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    /// A `-1743` can be our own bundle's fault; that is a ship-blocking bug,
    /// not a user decision, and it is logged as such at launch.
    private func reportAutomationDefects() {
        let defects = AutomationSelfCheck.defects(in: AutomationSelfCheck.currentBundleConfig())
        guard !defects.isEmpty else { return }
        let names = defects.map(\.rawValue).joined(separator: ",")
        log.fault("bundle cannot send Apple Events: \(names, privacy: .public)")
    }

    // MARK: - Settings

    private func showSettings() {
        // Nil in the diagnostic and test-host runs, which never build the UI.
        settingsWindow?.show()
    }

    private func settingsActions() -> SettingsActions {
        var actions = SettingsActions()
        actions.rebuildIndex = { [weak self] in
            guard let self else { return }
            let coordinator = self.coordinator!
            Task {
                await coordinator.rebuild()
                self.settingsModel.health = self.health.snapshot()
            }
        }
        actions.openAccessibilitySettings = { NSWorkspace.shared.open(SystemSettingsLinks.accessibility) }
        actions.openAutomationSettings = { [weak self] in self?.automation.openSettings() }
        actions.requestAutomation = { [weak self] bundleID in self?.offerTabs(for: bundleID) }
        actions.grantSafariCacheAccess = { [weak self] in
            guard let self else { return }
            NSApp.activate()
            let granted = FaviconStore.shared.requestSafariCacheAccess()
            self.statusMenu.safariCacheGranted = granted
            self.settingsModel.safariCacheGranted = granted
        }
        actions.refreshHealth = { [weak self] in
            guard let self else { return }
            self.settingsModel.health = self.health.snapshot()
        }
        // A Carbon hotkey is consumed before any window sees it, so the
        // shortcut field could never be shown the chord it is replacing.
        actions.setRecording = { [weak self] recording in
            guard let self else { return }
            if recording {
                self.hotKeys.unregisterPersistent()
            } else {
                self.hotKeys.registerPersistent()
            }
        }
        actions.automationPaneExists = { [weak self] in self?.settings.hasRequestedAutomation ?? false }
        return actions
    }

    /// One setting changed; only that one is applied, and it takes effect
    /// now rather than at the next launch.
    private func apply(_ setting: Setting) {
        switch setting {
        case .launchAtLogin:
            log.notice("launch at login=\(self.settings.launchesAtLogin, privacy: .public)")
        case .showMenuBarIcon:
            statusMenu.isIconVisible = settings.showMenuBarIcon
        case .appearance:
            Theme.apply(Theme.Style(textScale: settings.textSize.scale, isWide: settings.widePanel))
            panel.screenPosition = settings.panelPosition
            // SwiftUI reuses a row whose contents did not change, which would
            // otherwise leave it drawn at the old size.
            model.styleGeneration += 1
        case .sortMode:
            coordinator.sortMode = settings.sortMode
        case .includesPrivateTabs:
            let includes = settings.includesPrivateTabs
            providers.includesPrivate = includes
            coordinator.setIncludesPrivateTabs(includes)
            rebuildIndex()
        case .remoteFavicons:
            FaviconStore.shared.isRemoteLookupEnabled = settings.remoteFavicons
            statusMenu.faviconRemoteEnabled = settings.remoteFavicons
            log.notice("favicon remote lookup enabled=\(self.settings.remoteFavicons, privacy: .public)")
        case .cmdTabTakeover:
            applyCmdTabTakeover()
        case .hotKeys:
            hotKeys.configure(main: settings.mainHotKey, reverse: settings.reverseHotKey,
                              search: settings.searchHotKey)
        case .ignoreTitlePatterns:
            coordinator.setIgnoreTitlePatterns(settings.ignoreTitlePatterns)
            rebuildIndex()
        }
    }

    private func rebuildIndex() {
        let coordinator = coordinator!
        Task { await coordinator.rebuild() }
    }

    /// The app's own chords must be bound only while the system ones are off,
    /// and released before they go back: a registration made while the system
    /// owns the chord returns success and receives nothing.
    private func applyCmdTabTakeover() {
        if settings.cmdTabTakeover {
            guard offSpace.cmdTab.enable() else {
                log.error("Cmd+Tab takeover unavailable")
                settingsModel.cmdTabTakeoverAvailable = false
                return
            }
            hotKeys.registerCommandTab()
        } else {
            hotKeys.unregisterCommandTab()
            offSpace.cmdTab.disable()
        }
    }

    // MARK: - First run

    private func startOnboardingIfNeeded() {
        guard !settings.hasCompletedOnboarding else { return }
        let controller = OnboardingWindowController()
        onboarding = controller
        controller.onFinish = { [weak self] in
            guard let self else { return }
            self.settings.hasCompletedOnboarding = true
            self.onboarding = nil
            // The browser consent prompts were held back so they could not
            // land in front of the first-run window.
            Task { await self.onboardAutomation() }
        }
        controller.show(hotKeys: (settings.mainHotKey, settings.reverseHotKey, settings.searchHotKey))
    }

    static func frontmostAppInfo() -> AppInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AppInfo(bundleID: app.bundleIdentifier ?? "", pid: app.processIdentifier,
                       localizedName: app.localizedName ?? "")
    }
}
