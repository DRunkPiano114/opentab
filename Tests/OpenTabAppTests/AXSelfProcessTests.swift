import AppKit
import OpenTabAX
import OpenTabCore
import XCTest

/// Exercises the AX layer against this process's own windows. Same-process
/// AX needs no Accessibility grant, so these run in CI.
@MainActor
final class AXSelfProcessTests: XCTestCase {
    private var windowA: NSWindow!
    private var windowB: NSWindow!

    private var selfApp: AppInfo {
        AppInfo(bundleID: Bundle.main.bundleIdentifier!, pid: getpid(), localizedName: "OpenTab")
    }

    /// Unique per test: a window closed by the previous test can still be in
    /// the AX list for a moment, and a shared title would count it.
    private let run = UUID().uuidString.prefix(8)

    override func setUp() async throws {
        AXConfiguration.configureGlobalTimeout()
        windowA = makeWindow(title: "OpenTab AX Test A \(run)", x: 120)
        windowB = makeWindow(title: "OpenTab AX Test B \(run)", x: 520)
    }

    override func tearDown() async throws {
        for window in [windowA, windowB] {
            window?.close()
        }
        windowA = nil
        windowB = nil
        unsetenv("OPENTAB_DISABLE_AXGETWINDOW")
    }

    // MARK: Tests

    func testListsOwnWindowsWithCGKeysAndMinimizedFlags() async throws {
        let source = AXWindowSource()
        XCTAssertTrue(source.isWindowIDBridgeAvailable)

        let snapshots = try await snapshotsContaining([windowA, windowB], from: source)
        let a = try XCTUnwrap(snapshots[key(of: windowA)])
        let b = try XCTUnwrap(snapshots[key(of: windowB)])
        XCTAssertFalse(a.isMinimized)
        XCTAssertFalse(b.isMinimized)
        XCTAssertEqual(a.level, 0)
        XCTAssertEqual(a.title, "OpenTab AX Test A \(run)")
        XCTAssertEqual(b.title, "OpenTab AX Test B \(run)")
        XCTAssertTrue(a.isOnActiveSpace)
        XCTAssertEqual(a.app, selfApp)
    }

    func testMinimizedWindowStaysListedWithMinimizedFlag() async throws {
        let source = AXWindowSource()
        _ = try await snapshotsContaining([windowA, windowB], from: source)

        windowB.miniaturize(nil)
        try await poll("window B miniaturized") { self.windowB.isMiniaturized }

        var listed: WindowSnapshot?
        try await poll("minimized window B listed as minimized") {
            let snapshots = try await self.snapshotsByKey(from: source)
            listed = snapshots[self.key(of: self.windowB)]
            return listed?.isMinimized == true
        }
        XCTAssertEqual(listed?.isMinimized, true)
        let a = try await snapshotsByKey(from: source)[key(of: windowA)]
        XCTAssertEqual(a?.isMinimized, false)
    }

    func testFocusedWindowIsFlagged() async throws {
        let source = AXWindowSource()
        windowA.makeKeyAndOrderFront(nil)
        let snapshots = try await snapshotsContaining([windowA, windowB], from: source)
        guard NSApp.isActive else {
            // The host is an accessory app and may not be frontmost under xcodebuild.
            return
        }
        try await poll("window A reported focused") {
            try await self.snapshotsByKey(from: source)[self.key(of: self.windowA)]?.isFocused == true
        }
        XCTAssertEqual(snapshots.values.filter(\.isFocused).count <= 1, true)
    }

    func testFallsBackToAXKeysWhenBridgeDisabled() async throws {
        setenv("OPENTAB_DISABLE_AXGETWINDOW", "1", 1)
        let source = AXWindowSource()
        XCTAssertFalse(source.isWindowIDBridgeAvailable)

        let snapshots = try await source.snapshot(of: selfApp, deadline: .now + .seconds(2))
        let own = snapshots.filter { $0.title.hasSuffix(String(run)) }
        XCTAssertEqual(own.count, 2)
        for snapshot in own {
            guard case .ax(let pid, let elementID) = snapshot.key else {
                return XCTFail("expected an .ax key, got \(snapshot.key)")
            }
            XCTAssertEqual(pid, getpid())
            XCTAssertNotEqual(elementID, 0)
            XCTAssertNil(snapshot.level)
        }
        XCTAssertEqual(Set(own.map(\.key)).count, 2)
    }

    func testActivatorUnminimizesOwnWindow() async throws {
        let source = AXWindowSource()
        _ = try await snapshotsContaining([windowA, windowB], from: source)
        windowB.miniaturize(nil)
        try await poll("window B miniaturized") { self.windowB.isMiniaturized }
        _ = try await snapshotsContaining([windowB], from: source)

        let activator = AXWindowActivator(source: source)
        do {
            try await activator.activate(key(of: windowB), deadline: .now + .seconds(1))
        } catch AXActivationError.unconfirmed {
            // Focus confirmation needs the host to be frontmost; the window
            // state below is the assertion that matters here.
        }
        try await poll("window B deminiaturized") { !self.windowB.isMiniaturized }
        XCTAssertFalse(windowB.isMiniaturized)
    }

    func testActivatorRejectsUnknownKey() async throws {
        let activator = AXWindowActivator(source: AXWindowSource())
        do {
            try await activator.activate(.cg(0xFFFF_FFF0), deadline: .now + .seconds(1))
            XCTFail("expected unknownWindow")
        } catch AXActivationError.unknownWindow(let key) {
            XCTAssertEqual(key, .cg(0xFFFF_FFF0))
        }
    }

    func testExpiredDeadlineThrowsInsteadOfPartialList() async throws {
        let source = AXWindowSource()
        do {
            _ = try await source.snapshot(of: selfApp, deadline: .now - .milliseconds(1))
            XCTFail("expected deadlineExceeded")
        } catch AXSourceError.deadlineExceeded {
        }
    }

    // MARK: Helpers

    private func makeWindow(title: String, x: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: x, y: 200, width: 320, height: 200),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        // Under the "prefer tabs: always" system preference AppKit would merge
        // the two test windows into one tab group, which AX exposes as a
        // single window.
        window.tabbingMode = .disallowed
        window.orderFront(nil)
        return window
    }

    private func key(of window: NSWindow) -> WindowKey {
        .cg(UInt32(window.windowNumber))
    }

    private func snapshotsByKey(from source: AXWindowSource) async throws -> [WindowKey: WindowSnapshot] {
        let snapshots = try await source.snapshot(of: selfApp, deadline: .now + .seconds(2))
        return Dictionary(snapshots.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The window server can lag `orderFront` by a frame, so the first read
    /// may not see a fresh window yet.
    private func snapshotsContaining(_ windows: [NSWindow], from source: AXWindowSource) async throws
        -> [WindowKey: WindowSnapshot]
    {
        var result: [WindowKey: WindowSnapshot] = [:]
        try await poll("windows listed") {
            result = try await self.snapshotsByKey(from: source)
            return windows.allSatisfy { result[self.key(of: $0)] != nil }
        }
        return result
    }

    private func poll(_ what: String, timeout: Duration = .seconds(2),
                      until condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            if try await condition() { return }
            guard ContinuousClock.now < deadline else {
                return XCTFail("timed out waiting for \(what)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
