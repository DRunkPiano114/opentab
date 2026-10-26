import AppKit
import ApplicationServices
import OpenTabAX
import OpenTabCore
import OpenTabScript
import OpenTabWS
import XCTest
@testable import OpenTab

/// A native tab group on another Space, through the coordinator wired the
/// way the app wires it: a Finder window with three tabs goes full screen,
/// the desktop Space comes back, and the list must show the group as one row
/// carrying all three tabs. Choosing the second tab must switch to the
/// full-screen Space and select it.
///
/// Each Finder tab is a window of its own. Only the selected tab's window is
/// on a Space; the others are ordered out, and none of them may become a row.
///
/// Only windows this test opens are touched: the suite also runs on a Mac
/// with real Finder windows. Tabs are added through Finder's menu over
/// Accessibility; AppleScript to Finder would raise an Automation consent
/// prompt nobody can answer.
@MainActor
final class NativeTabGroupOffSpaceTests: XCTestCase {
    private static let calculatorURL = URL(fileURLWithPath: "/System/Applications/Calculator.app")
    private static let finderBundleID = "com.apple.finder"
    /// Shorter than the default so the background tabs' last sighting on a
    /// Space expires within the test.
    private static let noSpaceGrace: Duration = .seconds(2)

    /// Menu items are found by shortcut, which does not localise.
    private struct MenuShortcut {
        let key: String
        /// `AXMenuItemCmdModifiers`: 0 is Command alone, 1 adds Shift.
        let modifiers: Int

        static let newTab = MenuShortcut(key: "T", modifiers: 0)
        static let goToApplications = MenuShortcut(key: "A", modifiers: 1)
        static let goToUtilities = MenuShortcut(key: "U", modifiers: 1)
    }

    private struct Tab: Equatable {
        let title: String
        let isSelected: Bool
    }

    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private var previous: NSRunningApplication!
    private var calculator: NSRunningApplication?
    private var finder: NSRunningApplication!
    private var folder: URL?
    private var getWindow: GetWindow!
    /// The tab windows this test created, in creation order.
    private var created: [(id: CGWindowID, element: AXUIElement)] = []
    private let log = Log.make("tabgroup-test")

    override func setUp() async throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs the Accessibility grant")
        let symbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow"),
                                   "_AXUIElementGetWindow did not resolve")
        getWindow = unsafeBitCast(symbol, to: GetWindow.self)
        // With tabs always preferred, the folder window would open as a tab
        // of whatever Finder window is in front.
        try XCTSkipIf(UserDefaults.standard.string(forKey: "AppleWindowTabbingMode") == "always",
                      "new windows open as tabs of existing ones")
        AXConfiguration.configureGlobalTimeout()
        previous = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
        finder = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: Self.finderBundleID).first)

        // Calculator is the way back from the full-screen Space: launched
        // here, its window sits on this display's desktop Space.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let calculator = try await NSWorkspace.shared.openApplication(at: Self.calculatorURL, configuration: configuration)
        self.calculator = calculator
        try await poll("calculator has a window", timeout: .seconds(8)) {
            !self.axWindows(calculator.processIdentifier).isEmpty
        }

        let folder = FileManager.default.temporaryDirectory
            .appending(path: "OpenTab-TabGroup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
    }

    override func tearDown() async throws {
        await closeCreatedWindows()
        if let calculator {
            calculator.terminate()
            _ = await waitUntil(timeout: .seconds(3)) { calculator.isTerminated }
        }
        if let folder {
            try? FileManager.default.removeItem(at: folder)
        }
        if let previous {
            _ = previous.activate(options: [])
            _ = await waitUntil(timeout: .seconds(2)) { self.axFrontmost(previous.processIdentifier) == true }
        }
    }

    func testFullScreenFinderTabGroupIsOneRowAndSelectsTheChosenTab() async throws {
        let folder = try XCTUnwrap(folder)
        let pid = finder.processIdentifier
        let paths = [folder.path, "/Applications", "/Applications/Utilities"]
        let titles = paths.map { FileManager.default.displayName(atPath: $0) }

        var configuration = OffSpaceConfiguration()
        configuration.noSpaceGrace = Self.noSpaceGrace
        let offSpace = OffSpaceWindowSource(base: AXWindowSource(), configuration: configuration)
        try XCTSkipUnless(offSpace.isTokenPathActive, "the remote-token symbols did not resolve")
        let coordinator = makeCoordinator(offSpace)

        // The group is built on the desktop Space and read after every step,
        // so the source has seen each tab's window on a Space before it
        // became a background tab.
        try await openFolderWindow(folder, title: titles[0])
        await coordinator.refreshEverything()
        try await addTab(going: .goToApplications, title: titles[1])
        await coordinator.refreshEverything()
        try await addTab(going: .goToUtilities, title: titles[2])
        await coordinator.refreshEverything()
        let lastReadOnDesktop = ContinuousClock.now
        let group = try XCTUnwrap(created.last)
        XCTAssertEqual(tabStrip(of: group.element),
                       [Tab(title: titles[0], isSelected: false), Tab(title: titles[1], isSelected: false),
                        Tab(title: titles[2], isSelected: true)],
                       "the fixture group before full screen")

        try await enterFullScreenAndReturnToDesktop(group)

        let wait = Self.noSpaceGrace + .milliseconds(500) - lastReadOnDesktop.duration(to: .now)
        if wait > .zero { try await Task.sleep(for: wait) }
        let refreshStarted = ContinuousClock.now
        await coordinator.refreshEverything()
        let refreshTook = refreshStarted.duration(to: .now)
        let report = offSpace.report(for: pid)
        log.notice("""
            off-space refresh ms=\(Self.ms(refreshTook), privacy: .public) \
            report=\(String(describing: report), privacy: .public)
            """)

        let ids = created.map(\.id)
        let groupKeys = Set(ids.flatMap { [WindowKey.cg($0), Self.scriptWindow(for: $0)] })
        let rows = coordinator.entries.filter { groupKeys.contains($0.key) }
        let described = rows.map { "\($0.kind) \($0.key) onActiveSpace=\($0.isOnActiveSpace)" }
        XCTAssertEqual(rows.count, 1, "rows for the group's windows \(ids): \(described); report=\(String(describing: report))")
        for id in ids.dropLast() {
            XCTAssertFalse(rows.contains { $0.key == .cg(id) }, "background tab window \(id) is a row")
        }

        let scriptWindow = Self.scriptWindow(for: group.id)
        let row = try XCTUnwrap(rows.first { $0.key == scriptWindow },
                                "no tab row for window \(group.id): \(described); report=\(String(describing: report))")
        XCTAssertEqual(row.kind, .tab)
        XCTAssertEqual(row.title, titles[2], "the row shows the selected tab")
        XCTAssertFalse(row.isOnActiveSpace, "the full-screen window is off the active Space")
        XCTAssertEqual(coordinator.groupCounts.byWindowKey[scriptWindow], 3)
        XCTAssertEqual(coordinator.store.claimedWindow(for: scriptWindow), .cg(group.id))
        let tabs = coordinator.tabs(in: scriptWindow)
        XCTAssertEqual(tabs.map(\.title), titles)
        guard tabs.count == 3 else { return }

        let activationStarted = ContinuousClock.now
        await coordinator.activate(tabs[1])
        let activationTook = activationStarted.duration(to: .now)
        let second = created[1]
        let landed = await waitUntil(timeout: .seconds(5)) {
            guard self.axFrontmost(pid) == true, let window = self.focusedWindow(of: pid) else { return false }
            return self.windowID(of: window) == second.id && self.isOnscreen(second.id)
                && self.tabStrip(of: window).map(\.isSelected) == [false, true, false]
        }
        log.notice("tab activation ms=\(Self.ms(activationTook), privacy: .public) landed=\(landed, privacy: .public)")
        XCTAssertEqual(axFrontmost(pid), true, "Finder is frontmost")
        let focused = focusedWindow(of: pid)
        XCTAssertEqual(focused.flatMap(windowID(of:)), second.id, "the second tab's window is focused")
        XCTAssertTrue(isOnscreen(second.id), "the second tab's window is on screen")
        XCTAssertEqual(focused.map(tabStrip(of:)),
                       [Tab(title: titles[0], isSelected: false), Tab(title: titles[1], isSelected: true),
                        Tab(title: titles[2], isSelected: false)])
    }

    // MARK: - Wiring

    private func makeCoordinator(_ offSpace: OffSpaceWindowSource) -> SwitcherCoordinator {
        let tabs = AXTabProvider(offSpaceWindows: { offSpace.offSpaceWindows(for: $0) })
        return SwitcherCoordinator(source: offSpace, activator: OffSpaceWindowActivator(source: offSpace),
                                   directory: WorkspaceAppDirectory(),
                                   providers: TabProviderRegistry(engine: AppleScriptEngine(), includesPrivate: false,
                                                                  accessibility: tabs),
                                   gate: AutomationGateKeeper(),
                                   resolver: WindowResolver(directBridge: offSpace.base.isWindowIDBridgeAvailable),
                                   windowServer: WindowServerIDs.current)
    }

    private static func scriptWindow(for id: CGWindowID) -> WindowKey {
        .scripted(bundleID: finderBundleID, token: String(id))
    }

    // MARK: - Building the group

    private func openFolderWindow(_ folder: URL, title: String) async throws {
        let pid = finder.processIdentifier
        XCTAssertTrue(NSWorkspace.shared.open(folder))
        var opened: AXUIElement?
        try await poll("Finder window for the test folder", timeout: .seconds(8)) {
            opened = self.axWindows(pid).first { (self.attribute($0, kAXTitleAttribute) as? String) == title }
            return opened != nil
        }
        let window = try XCTUnwrap(opened)
        let id = try XCTUnwrap(windowID(of: window))
        if tabStrip(of: window).count > 1 {
            // Joined a group that is not ours: close only the tab that was
            // just opened.
            pressCloseButton(ofTabTitled: title, in: window)
            throw XCTSkip("the folder opened as a tab of an existing Finder window")
        }
        created.append((id, window))
        try await bringToFront(window, id: id)
    }

    /// New Tab in the group's window, then a Go menu item that shows a
    /// known folder in it.
    private func addTab(going destination: MenuShortcut, title: String) async throws {
        let pid = finder.processIdentifier
        let known = Set(created.map(\.id))
        let expectedCount = created.count + 1
        try pressMenuItem(.newTab, of: pid)
        var added: (id: CGWindowID, element: AXUIElement)?
        try await poll("tab \(expectedCount) focused", timeout: .seconds(5)) {
            guard let window = self.focusedWindow(of: pid), let id = self.windowID(of: window),
                  !known.contains(id), self.tabStrip(of: window).count == expectedCount else { return false }
            added = (id, window)
            return true
        }
        let tab = try XCTUnwrap(added)
        created.append(tab)
        try pressMenuItem(destination, of: pid)
        try await poll("tab \(expectedCount) shows its folder", timeout: .seconds(5)) {
            (self.attribute(tab.element, kAXTitleAttribute) as? String) == title
        }
    }

    private func bringToFront(_ window: AXUIElement, id: CGWindowID) async throws {
        let pid = finder.processIdentifier
        try await poll("test folder window focused", timeout: .seconds(5)) {
            if self.focusedWindow(of: pid).flatMap(self.windowID(of:)) == id, self.axFrontmost(pid) == true { return true }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFBoolean)
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, true as CFBoolean)
            return false
        }
    }

    private func enterFullScreenAndReturnToDesktop(_ group: (id: CGWindowID, element: AXUIElement)) async throws {
        let calculator = try XCTUnwrap(calculator)
        let pid = finder.processIdentifier
        // Finder answers the full-screen request only once the transition is
        // under way, well past the short process-wide messaging timeout.
        AXUIElementSetMessagingTimeout(group.element, 3)
        XCTAssertEqual(AXUIElementSetAttributeValue(group.element, "AXFullScreen" as CFString, true as CFBoolean), .success)
        try await poll("window reports full screen", timeout: .seconds(5)) {
            (self.attribute(group.element, "AXFullScreen") as? Bool) == true
        }
        // The transition animates for about a second and assigns the new
        // Space part-way through; switching away before it completes lands
        // back on the full-screen Space.
        try await poll("full-screen Space assigned", timeout: .seconds(5)) {
            self.isOnscreen(group.id) && !(OffSpaceDiagnostics.spaceIDs(of: group.id) ?? []).isEmpty
        }
        try await Task.sleep(for: .seconds(1.5))
        try await poll("full-screen Space off screen", timeout: .seconds(6)) {
            _ = calculator.activate(options: [])
            return !self.isOnscreen(group.id)
        }
        // While the Space switch animates the window is on no Space and AX
        // may still list it. Settled means off screen, on a Space, and gone
        // from Finder's AX windows (which still list its desktop windows).
        try await poll("full-screen window settled on its own Space", timeout: .seconds(8)) {
            !self.isOnscreen(group.id) && !(OffSpaceDiagnostics.spaceIDs(of: group.id) ?? []).isEmpty
                && !self.axWindows(pid).contains { self.windowID(of: $0) == group.id }
        }
    }

    // MARK: - Cleanup

    /// Leaves full screen, then closes the created tab windows one at a time
    /// through their own close buttons until the WindowServer lists none of
    /// them. Only the selected tab's window is in `kAXWindows`; closing it
    /// selects the next one.
    private func closeCreatedWindows() async {
        guard !created.isEmpty, let finder else { return }
        let pid = finder.processIdentifier
        let ids = Set(created.map(\.id))
        let fullScreen = created.filter { (attribute($0.element, "AXFullScreen") as? Bool) == true }
        for window in fullScreen {
            AXUIElementSetAttributeValue(window.element, "AXFullScreen" as CFString, false as CFBoolean)
        }
        if !fullScreen.isEmpty {
            _ = await waitUntil(timeout: .seconds(8)) {
                self.created.allSatisfy { (self.attribute($0.element, "AXFullScreen") as? Bool) != true }
            }
            // Closing a window while it animates out of full screen leaves
            // an empty Space behind.
            try? await Task.sleep(for: .seconds(1.5))
        }
        for _ in 0..<(created.count * 2) {
            let alive = ids.intersection(windowServerIDs(of: pid))
            guard !alive.isEmpty else { break }
            let target = axWindows(pid).first { windowID(of: $0).map(alive.contains) == true }
                ?? created.first { alive.contains($0.id) }?.element
            if let target, let button = element(target, kAXCloseButtonAttribute) {
                AXUIElementPerformAction(button, kAXPressAction as CFString)
            }
            _ = await waitUntil(timeout: .seconds(2)) {
                ids.intersection(self.windowServerIDs(of: pid)).count < alive.count
            }
        }
        let left = ids.intersection(windowServerIDs(of: pid))
        XCTAssertTrue(left.isEmpty, "test windows left open: \(left.sorted())")
        created = []
    }

    // MARK: - Accessibility

    private func pressMenuItem(_ shortcut: MenuShortcut, of pid: pid_t) throws {
        let app = AXUIElementCreateApplication(pid)
        guard let bar = element(app, kAXMenuBarAttribute) else {
            XCTFail("no menu bar for pid \(pid)")
            throw SetupFailure()
        }
        for barItem in children(of: bar) {
            for menu in children(of: barItem) {
                for item in children(of: menu) {
                    guard (attribute(item, kAXMenuItemCmdCharAttribute) as? String)?.uppercased() == shortcut.key,
                          (attribute(item, kAXMenuItemCmdModifiersAttribute) as? Int) == shortcut.modifiers,
                          (attribute(item, kAXEnabledAttribute) as? Bool) == true else { continue }
                    XCTAssertEqual(AXUIElementPerformAction(item, kAXPressAction as CFString), .success)
                    return
                }
            }
        }
        XCTFail("no enabled menu item for \(shortcut)")
        throw SetupFailure()
    }

    private struct SetupFailure: Error {}

    /// The window's tab buttons in strip order. Finder hides the strip, and
    /// with it the tab group, while a window has one tab.
    private func tabStrip(of window: AXUIElement) -> [Tab] {
        guard let group = tabGroup(of: window) else { return [] }
        return children(of: group)
            .filter { (attribute($0, kAXRoleAttribute) as? String) == kAXRadioButtonRole }
            .map { button in
                let title = (attribute(button, kAXTitleAttribute) as? String) ?? ""
                let label = title.isEmpty ? (attribute(button, kAXDescriptionAttribute) as? String) ?? "" : title
                return Tab(title: label, isSelected: (attribute(button, kAXValueAttribute) as? Int) == 1)
            }
    }

    private func tabGroup(of window: AXUIElement) -> AXUIElement? {
        var level = [window]
        for _ in 0..<4 {
            var next: [AXUIElement] = []
            for node in level {
                for child in children(of: node) {
                    if (attribute(child, kAXRoleAttribute) as? String) == kAXTabGroupRole { return child }
                    next.append(child)
                }
            }
            level = next
        }
        return nil
    }

    private func pressCloseButton(ofTabTitled title: String, in window: AXUIElement) {
        guard let group = tabGroup(of: window),
              let tab = children(of: group).first(where: { (attribute($0, kAXTitleAttribute) as? String) == title }),
              let button = children(of: tab).first(where: { (attribute($0, kAXRoleAttribute) as? String) == kAXButtonRole })
        else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private func axWindows(_ pid: pid_t) -> [AXUIElement] {
        (attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    private func focusedWindow(of pid: pid_t) -> AXUIElement? {
        element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)
    }

    private func axFrontmost(_ pid: pid_t) -> Bool? {
        attribute(AXUIElementCreateApplication(pid), kAXFrontmostAttribute) as? Bool
    }

    private func windowID(of window: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard getWindow(window, &id) == .success, id != 0 else { return nil }
        return id
    }

    // MARK: - WindowServer

    private func isOnscreen(_ id: CGWindowID) -> Bool {
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return info.contains { ($0[kCGWindowNumber as String] as? Int) == Int(id) }
    }

    /// Window numbers only; names are never read.
    private func windowServerIDs(of pid: pid_t) -> Set<CGWindowID> {
        let info = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return Set(info.compactMap { row -> CGWindowID? in
            guard (row[kCGWindowOwnerPID as String] as? Int) == Int(pid),
                  let number = row[kCGWindowNumber as String] as? Int else { return nil }
            return CGWindowID(number)
        })
    }

    // MARK: - Waiting

    private func poll(_ what: String, timeout: Duration, until condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            if try await condition() { return }
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out waiting for \(what)")
                throw SetupFailure()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// For cleanup and for outcomes asserted separately: a timeout is not a
    /// failure by itself.
    private func waitUntil(timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    private static func ms(_ duration: Duration) -> String {
        let parts = duration.components
        return String(format: "%.0f", Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15)
    }
}
