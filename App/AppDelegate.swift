import AppKit
import OpenTabAX
import OpenTabCore

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
    private var index: WindowIndex!
    private var trigger: AXRefreshTrigger!
    private var trustPoll: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app-hosted test bundle loads this binary as its host; the tests
        // drive the pieces they need themselves.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }

        AXConfiguration.configureGlobalTimeout()
        log.notice("""
            launched bundle=\(Bundle.main.bundleIdentifier ?? "nil", privacy: .public) \
            axTrusted=\(AXTrust.isTrusted, privacy: .public) \
            path=\(Bundle.main.bundlePath, privacy: .public)
            """)

        if let outDir = SelfTest.outputDirectory(from: CommandLine.arguments) {
            Task { await SelfTest.run(outputDirectory: outDir) }
            return
        }

        let rules = IgnoreRules(titlePatterns: UserDefaults.standard.stringArray(forKey: "ignoreTitlePatterns") ?? [])
        source = AXWindowSource()
        directory = WorkspaceAppDirectory(ignoreRules: rules)
        index = WindowIndex(source: source, directory: directory, ignoreRules: rules)
        trigger = AXRefreshTrigger()

        model = PanelViewModel()
        panel = PanelController(model: model)
        hotKeys = HotKeyCenter()
        session = SwitcherSession(index: index, activator: AXWindowActivator(source: source),
                                  panel: panel, hotKeys: hotKeys, model: model)
        session.frontmostApp = { Self.frontmostAppInfo() }

        statusMenu = StatusMenuController()
        statusMenu.windowIDBridgeAvailable = source.isWindowIDBridgeAvailable
        statusMenu.onRebuildIndex = { [weak self] in
            guard let self else { return }
            Task { await self.index.rebuild() }
        }
        if !source.isWindowIDBridgeAvailable {
            log.error("_AXUIElementGetWindow unavailable: windows keyed by AX element only")
        }

        secureInput = SecureInputMonitor()
        secureInput.onChange = { [weak self] active in
            self?.statusMenu.secureInputActive = active
            self?.log.notice("secure input active=\(active, privacy: .public)")
        }
        secureInput.start()

        panel.prewarm()
        session.start()

        if AXTrust.isTrusted {
            accessibilityGranted()
        } else {
            statusMenu.accessibilityGranted = false
            AXTrust.prompt()
            startTrustPolling()
        }
    }

    /// Accessibility grants take effect without a relaunch; a 1s poll is
    /// enough to notice and bring the rest of the app up.
    private func startTrustPolling() {
        trustPoll?.cancel()
        trustPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if AXTrust.isTrusted {
                    self?.accessibilityGranted()
                    return
                }
            }
        }
    }

    private func accessibilityGranted() {
        trustPoll?.cancel()
        trustPoll = nil
        log.notice("accessibility granted")
        statusMenu.accessibilityGranted = true
        trigger.start()
        index.start(trigger: trigger)
        session.accessibilityGranted()
        Task {
            await index.refreshAll()
            IconCache.shared.prewarm(apps: directory.runningApps())
            log.notice("initial index: \(self.index.entries.count, privacy: .public) windows")
        }
    }

    static func frontmostAppInfo() -> AppInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AppInfo(bundleID: app.bundleIdentifier ?? "", pid: app.processIdentifier,
                       localizedName: app.localizedName ?? "")
    }
}
