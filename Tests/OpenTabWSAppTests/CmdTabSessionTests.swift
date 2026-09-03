import AppKit
import ApplicationServices
import Carbon
import OpenTabAX
import OpenTabCore
import OpenTabScript
import OpenTabWS
import XCTest
import os
@testable import OpenTab

/// The Cmd+Tab takeover the way a user drives it (keymap.md §3, E2): with
/// the system chords disabled, synthetic HID keys reach the real
/// `HotKeyCenter` bindings, the session opens on Cmd+Tab, walks on Tab and
/// Cmd+Shift+Tab, and commits on the Cmd release seen by the modifier
/// monitors. The system switcher must never appear (Dock windows), and the
/// only frontmost change is the one we asked for.
@MainActor
final class CmdTabSessionTests: XCTestCase {
    private static let calculatorURL = URL(fileURLWithPath: "/System/Applications/Calculator.app")

    private enum Key {
        static let tab: CGKeyCode = 48
        static let command: CGKeyCode = 55
    }

    private var previous: NSRunningApplication!
    private var calculator: NSRunningApplication!
    private var defaults: UserDefaults!
    private var suite: String!
    private var original: [Int32: Bool] = [:]
    private var takeover: CmdTabTakeover!
    private var model: PanelViewModel!
    private var panel: PanelController!
    private var hotKeys: HotKeyCenter!
    private var coordinator: SwitcherCoordinator!
    private var session: SwitcherSession!
    private let log = Log.make("cmdtab-test")

    override func setUp() async throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs the Accessibility grant")
        try XCTSkipUnless(CmdTabTakeover.isAvailable, "CGSSetSymbolicHotKeyEnabled unavailable")
        previous = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
        suite = "im.opentab.app.tests.ws.session.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        original = CmdTabTakeover.systemState()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        calculator = try await NSWorkspace.shared.openApplication(at: Self.calculatorURL, configuration: configuration)

        let source = AXWindowSource()
        let offSpace = OffSpaceWindowSource(base: source)
        // Calculator has no tab provider, so the real registry and gate are
        // inert here.
        coordinator = SwitcherCoordinator(source: offSpace, activator: OffSpaceWindowActivator(source: offSpace),
                                          directory: WorkspaceAppDirectory(),
                                          providers: TabProviderRegistry(engine: AppleScriptEngine(), includesPrivate: false),
                                          gate: AutomationGateKeeper(), resolver: nil,
                                          windowServer: WindowServerIDs.current)
        model = PanelViewModel()
        panel = PanelController(model: model)
        hotKeys = HotKeyCenter()
        session = SwitcherSession(coordinator: coordinator, panel: panel, hotKeys: hotKeys, model: model)
        session.frontmostApp = { AppDelegate.frontmostAppInfo() }
        panel.prewarm()
        session.start()
        try await poll("calculator indexed", timeout: .seconds(5)) {
            await self.coordinator.refreshAll(seedFocus: true)
            return self.coordinator.entries.contains { $0.app.pid == self.calculator.processIdentifier }
        }

        takeover = CmdTabTakeover(defaults: defaults)
        XCTAssertTrue(takeover.enable())
        XCTAssertEqual(CmdTabTakeover.systemState(), [1: false, 2: false])
        hotKeys.registerCommandTab()
    }

    override func tearDown() async throws {
        if HoldModifier.command.currentlyHeld {
            post(Key.command, down: false)
            settle(0.1)
        }
        if panel?.isVisible == true {
            panel.hide()
        }
        hotKeys?.unregisterCommandTab()
        hotKeys?.unregisterNavigationKeys()
        takeover?.disable()
        CmdTabTakeover.setSystemState(original)
        XCTAssertEqual(CmdTabTakeover.systemState(), original, "the system chords come back as found")
        defaults?.removePersistentDomain(forName: suite)
        if let calculator {
            calculator.terminate()
            try? await poll("calculator terminated", timeout: .seconds(3)) { calculator.isTerminated }
        }
        if let previous {
            _ = previous.activate(options: [])
            try? await poll("previous app frontmost again", timeout: .seconds(2)) {
                self.axFrontmost(previous.processIdentifier) == true
            }
        }
    }

    func testCmdTabOpensWalksAndCommitsOnCommandRelease() throws {
        let observer = FlickerObserver()
        observer.start()

        post(Key.command, down: true, flags: .maskCommand)
        settle(0.05)
        // Which state sources see a synthetic Command press: the session
        // state does not, so the session relies on the monitors for it.
        let combined = CGEventSource.flagsState(.combinedSessionState)
        let hid = CGEventSource.flagsState(.hidSystemState)
        log.notice("after Cmd down: combined cmd=\(combined.contains(.maskCommand), privacy: .public) hid cmd=\(hid.contains(.maskCommand), privacy: .public) nsevent cmd=\(NSEvent.modifierFlags.contains(.command), privacy: .public) monitor=\(self.hotKeys.isHeld(.command), privacy: .public)")
        XCTAssertTrue(hotKeys.isHeld(.command), "the monitors must have seen the Cmd press")
        post(Key.tab, flags: .maskCommand)
        try wait("panel opened on Cmd+Tab", 1.5) { self.panel.isVisible }
        XCTAssertEqual(model.mode, .navigating)
        XCTAssertFalse(NSApp.isActive, "navigation must not activate the app")
        XCTAssertEqual(model.selectedIndex, 1, "opens on the second row like Option+Tab")

        post(Key.tab, flags: .maskCommand)
        try wait("Cmd+Tab moved down", 1.0) { self.model.selectedIndex == 2 % max(self.model.rows.count, 1) }
        post(Key.tab, flags: [.maskCommand, .maskShift])
        try wait("Cmd+Shift+Tab moved up", 1.0) { self.model.selectedIndex == 1 }

        // Walk to Calculator's row, then let go of Cmd.
        let target = try XCTUnwrap(model.rows.firstIndex { $0.appName == calculator.localizedName },
                                   "\(model.rows.map(\.appName))")
        var guardCount = 0
        while model.selectedIndex != target, guardCount < model.rows.count {
            post(Key.tab, flags: .maskCommand)
            settle(0.08)
            guardCount += 1
        }
        XCTAssertEqual(model.selectedIndex, target)
        post(Key.command, down: false)
        try wait("panel closed on Cmd release", 1.0) { !self.panel.isVisible }
        try wait("calculator frontmost", 1.5) { self.axFrontmost(self.calculator.processIdentifier) == true }
        settle(0.5)
        let counts = observer.stop()
        log.notice("cmd-tab session frontmostChanges=\(counts.frontmostChanges, privacy: .public) dockWindowsAppeared=\(counts.dockWindowsAppeared, privacy: .public)")
        XCTAssertEqual(counts.dockWindowsAppeared, 0, "the system switcher must not appear")
        XCTAssertEqual(counts.frontmostChanges, 1, "only the activation we asked for")
    }

    func testDisableRestoresTheSystemChords() {
        XCTAssertEqual(CmdTabTakeover.systemState(), [1: false, 2: false])
        hotKeys.unregisterCommandTab()
        takeover.disable()
        XCTAssertEqual(CmdTabTakeover.systemState(), original)
    }

    // MARK: - Driving

    private func post(_ key: CGKeyCode, flags: CGEventFlags = []) {
        post(key, down: true, flags: flags)
        post(key, down: false, flags: flags)
    }

    private func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else {
            return XCTFail("could not create event for key \(key)")
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func wait(_ what: String, _ seconds: TimeInterval, until condition: () -> Bool) throws {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !condition(), Date() < deadline { settle(0.03) }
        guard condition() else {
            XCTFail("timed out waiting for \(what): visible=\(panel.isVisible) selected=\(model.selectedIndex) rows=\(model.rows.count)")
            throw SetupFailure()
        }
    }

    private struct SetupFailure: Error {}

    /// Dispatches events while waiting: the Carbon handler and the monitors
    /// need the event loop to turn.
    private func settle(_ seconds: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            guard let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) else { break }
            NSApp.sendEvent(event)
        }
    }

    private func poll(_ what: String, timeout: Duration, until condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            if try await condition() { return }
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func axFrontmost(_ pid: pid_t) -> Bool? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, &value)
        return error == .success ? (value as? Bool) : nil
    }
}
