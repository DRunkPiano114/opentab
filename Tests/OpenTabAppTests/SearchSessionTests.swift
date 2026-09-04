import AppKit
import ApplicationServices
import Carbon
import OpenTabAX
import OpenTabCore
import XCTest
import os
@testable import OpenTab

/// The whole navigation-to-search path, driven the way a user drives it:
/// synthetic HID keys through the real Carbon hotkeys into a real session,
/// index, panel and search field, with Calculator as the target and the
/// Pinyin input method composing the query. Judged by the panel's state and
/// the target's own `kAXFrontmostAttribute`.
@MainActor
final class SearchSessionTests: XCTestCase {
    private static let calculatorURL = URL(fileURLWithPath: "/System/Applications/Calculator.app")
    private static let pinyinID = "com.apple.inputmethod.SCIM.ITABC"

    private enum Key {
        static let a: CGKeyCode = 0
        static let c: CGKeyCode = 8
        static let l: CGKeyCode = 37
        static let tab: CGKeyCode = 48
        static let `return`: CGKeyCode = 36
        static let escape: CGKeyCode = 53
        static let option: CGKeyCode = 58
    }

    private struct SetupFailure: Error {}

    private var previous: NSRunningApplication!
    private var calculator: NSRunningApplication!
    private var originalSource: TISInputSource?
    private var model: PanelViewModel!
    private var panel: PanelController!
    private var hotKeys: HotKeyCenter!
    private var coordinator: SwitcherCoordinator!
    private var session: SwitcherSession!
    private let log = Log.make("session-test")

    override func setUp() async throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs the Accessibility grant")
        originalSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        if Self.identifier(of: originalSource!) != Self.pinyinID {
            guard let pinyin = Self.enabledSource(id: Self.pinyinID) else {
                throw XCTSkip("Pinyin - Simplified is not enabled")
            }
            XCTAssertEqual(TISSelectInputSource(pinyin), noErr)
        }
        previous = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        calculator = try await NSWorkspace.shared.openApplication(at: Self.calculatorURL, configuration: configuration)

        let source = AXWindowSource()
        let directory = WorkspaceAppDirectory()
        coordinator = SwitcherCoordinator(source: source, activator: AXWindowActivator(source: source),
                                          directory: directory, providers: FakeProviderLookup(),
                                          gate: FakeAutomationGate(), resolver: nil,
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
    }

    override func tearDown() async throws {
        if panel?.isVisible == true {
            post(Key.escape)
            settle(0.2)
        }
        panel?.hide()
        hotKeys?.unregisterNavigationKeys()
        if let calculator {
            calculator.terminate()
            // The next test relaunches it at once; LaunchServices answers
            // procNotFound while the old process is still going away.
            try? await poll("calculator terminated", timeout: .seconds(3)) { calculator.isTerminated }
        }
        if let originalSource,
           Self.identifier(of: TISCopyCurrentKeyboardInputSource().takeRetainedValue()) != Self.identifier(of: originalSource) {
            TISSelectInputSource(originalSource)
        }
        if let previous {
            _ = previous.activate(options: [])
            try? await poll("previous app frontmost again", timeout: .seconds(2)) {
                self.axFrontmost(previous.processIdentifier) == true
            }
        }
    }

    func testEnterThenPinyinQueryThenReturnActivatesTarget() throws {
        openPanelWithOptionTab()
        XCTAssertEqual(model.mode, .navigating)
        XCTAssertFalse(NSApp.isActive, "navigation must not activate the app")

        // Return while Option is still held enters search (Option+Return binding).
        post(Key.return, flags: .maskAlternate)
        try wait("search entered", 1.0) { self.model.mode == .searching && NSApp.isActive }
        XCTAssertTrue(panel.panel.isKeyWindow)

        // Letting go of Option in search must not commit.
        post(Key.option, down: false)
        settle(0.15)
        XCTAssertEqual(model.mode, .searching)
        XCTAssertTrue(panel.isVisible)

        try requireKeyboardOwnership()
        // The input method attaches to a fresh input context about 500ms
        // after the first activation in a process; keys before that are
        // inserted raw instead of composed.
        settle(0.7)
        for key in [Key.c, Key.a, Key.l, Key.c] { post(key); settle(0.08) }
        try wait("results filtered while composing", 1.0) {
            self.model.isFiltered && !self.model.rows.isEmpty
        }
        // Fuzzy matching admits other rows; the best hit must be the app.
        XCTAssertEqual(model.rows.first?.appName, calculator.localizedName, "\(model.rows.map(\.appName))")
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertTrue(panel.searchField.hasMarkedText, "the IME should still be composing")
        snapshotPanel(named: "search-composing")

        // Return during composition belongs to the IME: the panel stays.
        post(Key.return)
        settle(0.2)
        XCTAssertEqual(model.mode, .searching)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.searchField.hasMarkedText)
        XCTAssertTrue(model.isFiltered && !model.rows.isEmpty)

        // Return with nothing pending commits the selected row.
        post(Key.return)
        try wait("panel closed", 1.0) { !self.panel.isVisible }
        try wait("calculator frontmost", 1.5) { self.axFrontmost(self.calculator.processIdentifier) == true }
    }

    func testEscapeFromEmptySearchRestoresPreviousApp() throws {
        openPanelWithOptionTab()
        post(Key.return, flags: .maskAlternate)
        try wait("search entered", 1.0) { self.model.mode == .searching && NSApp.isActive }
        post(Key.option, down: false)
        settle(0.1)

        try requireKeyboardOwnership()
        post(Key.escape)
        try wait("panel closed", 1.0) { !self.panel.isVisible }
        try wait("previous app frontmost", 1.5) { self.axFrontmost(self.previous.processIdentifier) == true }
        XCTAssertEqual(model.mode, .navigating)
    }

    func testEscapeClearsQueryBeforeClosing() throws {
        openPanelWithOptionTab()
        post(Key.return, flags: .maskAlternate)
        try wait("search entered", 1.0) { self.model.mode == .searching && NSApp.isActive }
        post(Key.option, down: false)
        settle(0.1)

        try requireKeyboardOwnership()
        settle(0.7)
        for key in [Key.c, Key.a] { post(key); settle(0.08) }
        post(Key.return)   // commit the raw letters
        try wait("filtered", 1.0) { self.model.isFiltered }
        post(Key.escape)
        try wait("query cleared", 1.0) { !self.model.isFiltered }
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(model.mode, .searching)
        XCTAssertEqual(panel.searchField.text, "")
    }

    // MARK: - Driving

    private func openPanelWithOptionTab() {
        post(Key.option, down: true, flags: .maskAlternate)
        settle(0.05)
        post(Key.tab, flags: .maskAlternate)
        let deadline = Date(timeIntervalSinceNow: 1.5)
        while !panel.isVisible, Date() < deadline { settle(0.05) }
        XCTAssertTrue(panel.isVisible, "Option+Tab did not open the panel")
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

    /// Text keys go wherever the keyboard focus is, so they are posted only
    /// once the AX server says this process holds it.
    private func requireKeyboardOwnership() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let deadline = Date(timeIntervalSinceNow: 0.5)
        while Self.systemFocusedPid() != pid, Date() < deadline { settle(0.02) }
        guard NSApp.isActive, panel.panel.isKeyWindow, Self.systemFocusedPid() == pid else {
            XCTFail("refusing to type: active=\(NSApp.isActive) key=\(panel.panel.isKeyWindow) focusedPid=\(Self.systemFocusedPid().map(String.init) ?? "nil")")
            throw SetupFailure()
        }
    }

    private func wait(_ what: String, _ seconds: TimeInterval, until condition: () -> Bool) throws {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !condition(), Date() < deadline { settle(0.03) }
        guard condition() else {
            XCTFail("timed out waiting for \(what): mode=\(model.mode) visible=\(panel.isVisible) active=\(NSApp.isActive) rows=\(model.rows.count) filtered=\(model.isFiltered)")
            throw SetupFailure()
        }
    }

    /// Dispatches events while waiting: a nested `RunLoop.run` never dequeues
    /// `NSEvent`s, and the Carbon hotkey handler and the field both need them.
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

    /// Renders the panel's content view (SwiftUI host plus the AppKit field)
    /// to build/out for a visual check of the search-state layout.
    private func snapshotPanel(named name: String) {
        guard let view = panel.panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/out", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    // MARK: - Probes

    private func axFrontmost(_ pid: pid_t) -> Bool? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, &value)
        return error == .success ? (value as? Bool) : nil
    }

    private static func systemFocusedPid() -> pid_t? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(value as! AXUIElement, &pid) == .success else { return nil }
        return pid
    }

    private static func identifier(of source: TISInputSource) -> String {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func enabledSource(id: String) -> TISInputSource? {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.first { identifier(of: $0) == id }
    }
}
