import AppKit
import ApplicationServices
import Carbon
import OpenTabAX
import OpenTabCore
import XCTest
@testable import OpenTab

/// Return in the tab pane, driven the way a user drives it: synthetic HID
/// keys through the real Carbon hotkeys into a real session and panel, over a
/// fake browser window with three tabs. Judged by what the provider was asked
/// to select and by whether the app ever activated, which only search does.
@MainActor
final class DetailSessionTests: XCTestCase {
    private enum Key {
        static let tab: CGKeyCode = 48
        static let `return`: CGKeyCode = 36
        static let escape: CGKeyCode = 53
        static let option: CGKeyCode = 58
        static let down: CGKeyCode = 125
        static let right: CGKeyCode = 124
    }

    /// The keyboard sets these on every arrow key; a posted arrow without
    /// them never fires its Carbon hotkey.
    private static let arrowFlags: CGEventFlags = [.maskNumericPad, .maskSecondaryFn]

    private struct SetupFailure: Error {}

    private var previous: NSRunningApplication!
    private var activator: FakeActivator!
    private var provider: FakeTabProvider!
    private var model: PanelViewModel!
    private var panel: PanelController!
    private var hotKeys: HotKeyCenter!
    private var coordinator: SwitcherCoordinator!
    private var session: SwitcherSession!

    override func setUp() async throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs the Accessibility grant")
        previous = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)

        let source = FakeWindowSource()
        let directory = FakeAppDirectory()
        activator = FakeActivator()
        provider = FakeTabProvider(bundleIDs: [chrome.bundleID])
        coordinator = SwitcherCoordinator(source: source, activator: activator, directory: directory,
                                          providers: FakeProviderLookup([provider]), gate: FakeAutomationGate(),
                                          resolver: nil, windowServer: { nil })
        directory.set(apps: [chrome])
        source.set([chromeWindow(11, "one")], for: chrome)
        provider.set(tabs: [tab("a", "one", active: true), tab("b", "two"), tab("c", "three")])
        // Like a browser, the selected tab becomes the active one, so the
        // coordinator's landing check passes without a retry.
        provider.onActivate { tab, tabs in
            tabs = tabs.map { TabSnapshot(windowKey: $0.windowKey, token: $0.token, title: $0.title, url: $0.url,
                                          isActive: $0.token == tab.token, isPrivate: $0.isPrivate) }
        }
        await coordinator.refresh(app: chrome)
        let row = try XCTUnwrap(coordinator.entries.first)
        let window = try XCTUnwrap(coordinator.scriptWindow(for: row))
        XCTAssertEqual(coordinator.tabs(in: window).map(\.title), ["one", "two", "three"])

        model = PanelViewModel()
        panel = PanelController(model: model)
        hotKeys = HotKeyCenter()
        session = SwitcherSession(coordinator: coordinator, panel: panel, hotKeys: hotKeys, model: model)
        panel.prewarm()
        session.start()
    }

    override func tearDown() async throws {
        if panel?.isVisible == true {
            post(Key.escape)
            settle(0.2)
        }
        if HoldModifier.option.currentlyHeld {
            post(Key.option, down: false)
            settle(0.1)
        }
        panel?.hide()
        hotKeys?.unregisterPersistent()
        hotKeys?.unregisterNavigationKeys()
        if let previous {
            _ = previous.activate(options: [])
        }
    }

    func testReturnWithOptionHeldSwitchesToTheSelectedTab() throws {
        openPanelWithOptionTab()
        try openTabPaneOnSecondTab(flags: .maskAlternate)

        post(Key.return, flags: .maskAlternate)
        try wait("panel closed", 1.0) { !self.panel.isVisible }
        try wait("tab selected", 1.5) { !self.provider.activated.isEmpty }
        XCTAssertEqual(provider.activated.map(\.token), ["b"])
        XCTAssertFalse(NSApp.isActive, "Return in the tab pane must not enter search")
    }

    /// Opened from the menu bar no modifier is held, so plain Return is the
    /// binding that fires.
    func testPlainReturnSwitchesToTheSelectedTab() throws {
        session.openFromMenu(search: false)
        try wait("panel opened", 1.0) { self.panel.isVisible }
        try openTabPaneOnSecondTab(flags: [])

        post(Key.return)
        try wait("panel closed", 1.0) { !self.panel.isVisible }
        try wait("tab selected", 1.5) { !self.provider.activated.isEmpty }
        XCTAssertEqual(provider.activated.map(\.token), ["b"])
        XCTAssertFalse(NSApp.isActive, "Return in the tab pane must not enter search")
    }

    func testReturnInTheMainListStillEntersSearch() throws {
        openPanelWithOptionTab()
        XCTAssertNil(model.detail)

        post(Key.return, flags: .maskAlternate)
        try wait("search entered", 1.0) { self.model.mode == .searching }
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(provider.activated.isEmpty)
        XCTAssertTrue(activator.activated.isEmpty)
    }

    // MARK: - Driving

    private func tab(_ token: String, _ title: String, active: Bool = false) -> TabSnapshot {
        TabSnapshot(windowKey: .cg(11), token: token, title: title, url: nil, isActive: active, isPrivate: false)
    }

    private func openPanelWithOptionTab() {
        post(Key.option, down: true, flags: .maskAlternate)
        settle(0.05)
        post(Key.tab, flags: .maskAlternate)
        let deadline = Date(timeIntervalSinceNow: 1.5)
        while !panel.isVisible, Date() < deadline { settle(0.05) }
        XCTAssertTrue(panel.isVisible, "Option+Tab did not open the panel")
        XCTAssertFalse(NSApp.isActive, "navigation must not activate the app")
    }

    /// The pane opens on the tab the row stands for, the active one; Down
    /// moves off it so a commit of the row or of the first tab would show.
    private func openTabPaneOnSecondTab(flags: CGEventFlags) throws {
        post(Key.right, flags: flags.union(Self.arrowFlags))
        try wait("tab pane opened", 1.0) { self.model.detail != nil }
        XCTAssertEqual(model.detail?.rows.map(\.title), ["one", "two", "three"])
        XCTAssertEqual(selectedTabTitle, "one")
        post(Key.down, flags: flags.union(Self.arrowFlags))
        try wait("second tab selected", 1.0) { self.selectedTabTitle == "two" }
        XCTAssertEqual(model.mode, .navigating)
    }

    private var selectedTabTitle: String? {
        guard let rows = model.detail?.rows, rows.indices.contains(model.selectedIndex) else { return nil }
        return rows[model.selectedIndex].title
    }

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
            XCTFail("timed out waiting for \(what): mode=\(model.mode) visible=\(panel.isVisible) active=\(NSApp.isActive) detail=\(model.detail != nil) selected=\(model.selectedIndex) activated=\(provider.activated.map(\.token))")
            throw SetupFailure()
        }
    }

    /// Dispatches events while waiting: the Carbon handler, the modifier
    /// monitors and the activation task all need the event loop to turn.
    private func settle(_ seconds: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            guard let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) else { break }
            NSApp.sendEvent(event)
        }
    }
}
