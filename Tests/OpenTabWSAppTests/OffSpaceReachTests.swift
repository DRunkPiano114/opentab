import AppKit
import ApplicationServices
import OpenTabAX
import OpenTabCore
import OpenTabWS
import XCTest

/// The remote-token path against real processes, inside the signed app that
/// carries the Accessibility grant.
///
/// Calculator is the cross-check: the scan, given no AX windows, must land on
/// the same CGWindowID the AX enumeration reports. Dictionary (or another app
/// whose window accepts `AXFullScreen`) builds the one off-space scenario that
/// can be set up without a person: a fullscreen window on its own Space,
/// invisible to AX from the desktop Space, reached through the token, then
/// activated. Flicker is counted the way hkprobe does: Dock-owned windows
/// appearing and frontmost-app changes.
@MainActor
final class OffSpaceReachTests: XCTestCase {
    private static let calculatorURL = URL(fileURLWithPath: "/System/Applications/Calculator.app")
    private static let fullscreenCandidates = [
        "/System/Applications/Dictionary.app",
        "/System/Applications/Font Book.app",
        "/System/Applications/Chess.app",
    ]

    private var previous: NSRunningApplication!
    private var launched: [NSRunningApplication] = []
    private let log = Log.make("ws-test")

    override func setUp() async throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs the Accessibility grant")
        AXConfiguration.configureGlobalTimeout()
        previous = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
    }

    override func tearDown() async throws {
        for app in launched {
            app.terminate()
            try? await poll("\(app.bundleIdentifier ?? "app") terminated", timeout: .seconds(3)) { app.isTerminated }
        }
        launched = []
        if let previous {
            _ = previous.activate(options: [])
            try? await poll("previous app frontmost again", timeout: .seconds(2)) {
                self.axFrontmost(previous.processIdentifier) == true
            }
        }
    }

    // MARK: Calculator: token scan reproduces the AX answer

    func testTokenScanReachesTheWindowAXReports() async throws {
        let calculator = try await launch(Self.calculatorURL)
        let app = info(calculator)
        let base = AXWindowSource()
        let source = OffSpaceWindowSource(base: base)
        XCTAssertTrue(source.isTokenPathActive)

        let viaAX = try await source.snapshot(of: app, deadline: .now + .seconds(2))
        let axWindow = try XCTUnwrap(viaAX.first)
        guard case .cg(let wid) = axWindow.key else { return XCTFail("expected a .cg key") }
        XCTAssertTrue(axWindow.isOnActiveSpace, "Calculator was launched onto the current Space")
        XCTAssertEqual(source.report(for: app.pid)?.reachedViaToken, 0)

        // Pretend AX returned nothing: only the WindowServer row is left, and
        // the token scan must land on the same window.
        let started = ContinuousClock.now
        let viaToken = try await source.snapshotViaTokenOnly(of: app, deadline: .now + .seconds(5))
        let elapsed = started.duration(to: .now)
        let reached = try XCTUnwrap(viaToken.first { $0.key == .cg(wid) }, "report=\(String(describing: source.report(for: app.pid)))")
        XCTAssertEqual(reached.title, axWindow.title)
        XCTAssertEqual(reached.subrole, axWindow.subrole)
        XCTAssertEqual(reached.isMinimized, axWindow.isMinimized)
        XCTAssertTrue(reached.isOnActiveSpace)
        let report = try XCTUnwrap(source.report(for: app.pid))
        XCTAssertEqual(report.reachedViaToken, 1)
        let hits = source.hitElementIDs().first { $0.pid == app.pid }?.elementIDs ?? []
        XCTAssertEqual(hits.count, 1)
        log.notice("calculator token reach wid=\(wid, privacy: .public) elementID=\(hits.first ?? 0, privacy: .public) probed=\(report.probed, privacy: .public) ms=\(Self.ms(elapsed), privacy: .public)")
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    /// Filter validation: every window AX lists must pass the candidate
    /// filter, or a real off-space window of the same shape would be skipped.
    func testEveryAXWindowPassesTheCandidateFilter() async throws {
        let calculator = try await launch(Self.calculatorURL)
        let app = info(calculator)
        let snapshots = try await AXWindowSource().snapshot(of: app, deadline: .now + .seconds(2))
        XCTAssertFalse(snapshots.isEmpty)
        let info = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for snapshot in snapshots {
            guard case .cg(let wid) = snapshot.key else { continue }
            let row = try XCTUnwrap(info.first { ($0[kCGWindowNumber as String] as? Int) == Int(wid) })
            let bounds = CGRect(dictionaryRepresentation: row[kCGWindowBounds as String] as! CFDictionary) ?? .zero
            let alpha = row[kCGWindowAlpha as String] as? Double ?? 1
            XCTAssertGreaterThan(alpha, 0)
            XCTAssertGreaterThanOrEqual(min(bounds.width, bounds.height), 64, "wid \(wid) bounds \(bounds)")
        }
    }

    // MARK: Fullscreen: the off-space scenario without a person

    func testFullscreenWindowIsReachedOffSpaceAndActivated() async throws {
        // Calculator is the way back: launched here, so its window is on the
        // same display's desktop Space, and activating it switches that
        // display away from the fullscreen Space. The frontmost app at
        // setUp may live on another display and would not.
        let calculator = try await launch(Self.calculatorURL)
        guard let (target, window) = try await launchFullscreenCapable() else {
            throw XCTSkip("no launchable app with a settable AXFullScreen window")
        }
        let app = info(target)
        let source = OffSpaceWindowSource(base: AXWindowSource())
        let before = try await source.snapshot(of: app, deadline: .now + .seconds(2))
        let listed = try XCTUnwrap(before.first)
        guard case .cg(let wid) = listed.key else { return XCTFail("expected a .cg key") }
        logRows(of: app.pid, label: "before fullscreen")

        // Into fullscreen (its own Space), then back to the desktop Space so
        // the window is off-space from where we look.
        XCTAssertEqual(AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, true as CFBoolean), .success)
        try await poll("window reports fullscreen", timeout: .seconds(5)) {
            (self.attribute(window, "AXFullScreen") as? Bool) == true
        }
        // The transition animates for about a second and assigns the new
        // Space part-way through; switching away before it completes lands
        // back on the fullscreen Space.
        try await poll("fullscreen Space assigned", timeout: .seconds(5)) {
            self.isOnscreen(wid) && !(OffSpaceDiagnostics.spaceIDs(of: wid) ?? []).isEmpty
        }
        try await Task.sleep(for: .seconds(1.5))
        _ = calculator.activate(options: [])
        try await poll("fullscreen Space off screen", timeout: .seconds(6)) {
            _ = calculator.activate(options: [])
            return !self.isOnscreen(wid)
        }
        try await Task.sleep(for: .seconds(1))
        // The Space switch animates: while it runs the window is on no Space
        // at all and AX may still list it. Settled means off screen, on a
        // Space, and gone from AX.
        try await poll("fullscreen window settled on its own Space", timeout: .seconds(8)) {
            let spaces = OffSpaceDiagnostics.spaceIDs(of: wid) ?? []
            let count = self.axWindowCount(app.pid)
            self.log.notice("fullscreen settle onscreen=\(self.isOnscreen(wid), privacy: .public) spaces=\(String(describing: spaces), privacy: .public) axWindows=\(count, privacy: .public)")
            return !self.isOnscreen(wid) && !spaces.isEmpty && count == 0
        }

        logRows(of: app.pid, label: "fullscreen, desktop Space active")
        let offSpace = try await source.snapshot(of: app, deadline: .now + .seconds(5))
        let report = try XCTUnwrap(source.report(for: app.pid))
        let reached = try XCTUnwrap(offSpace.first { $0.key == .cg(wid) }, "off-space snapshot missing wid \(wid); report=\(report)")
        XCTAssertEqual(report.axWindows, 0)
        XCTAssertEqual(report.reachedViaToken, 1)
        XCTAssertFalse(reached.isOnActiveSpace, "a fullscreen window on another Space is off the active set")
        XCTAssertEqual(reached.title, listed.title)
        log.notice("fullscreen reach wid=\(wid, privacy: .public) probed=\(report.probed, privacy: .public) elementIDs=\(String(describing: source.hitElementIDs().first { $0.pid == app.pid }?.elementIDs), privacy: .public)")

        // Activate through the production activator and count flicker.
        let observer = FlickerObserver()
        observer.start()
        let activator = OffSpaceWindowActivator(source: source)
        let started = ContinuousClock.now
        try await activator.activate(.cg(wid), deadline: .now + .seconds(3))
        let activation = started.duration(to: .now)
        try await Task.sleep(for: .milliseconds(600))
        let counts = observer.stop()
        XCTAssertEqual(axFrontmost(app.pid), true)
        log.notice("fullscreen activation ms=\(Self.ms(activation), privacy: .public) frontmostChanges=\(counts.frontmostChanges, privacy: .public) dockWindowsAppeared=\(counts.dockWindowsAppeared, privacy: .public)")

        let after = try await source.snapshot(of: app, deadline: .now + .seconds(2))
        XCTAssertEqual(after.first { $0.key == .cg(wid) }?.isOnActiveSpace, true, "after activation the fullscreen Space is the active one")

        // Leave fullscreen before tearDown terminates the app.
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, false as CFBoolean)
        try? await poll("window left fullscreen", timeout: .seconds(5)) {
            (self.attribute(window, "AXFullScreen") as? Bool) == false
        }
    }

    /// Baseline for the flicker numbers: the same activator on a window that
    /// is on the current Space.
    func testActivationOnCurrentSpaceFlickerBaseline() async throws {
        let calculator = try await launch(Self.calculatorURL)
        let app = info(calculator)
        let source = OffSpaceWindowSource(base: AXWindowSource())
        let snapshots = try await source.snapshot(of: app, deadline: .now + .seconds(2))
        let key = try XCTUnwrap(snapshots.first).key
        let observer = FlickerObserver()
        observer.start()
        let started = ContinuousClock.now
        try await OffSpaceWindowActivator(source: source).activate(key, deadline: .now + .seconds(2))
        let activation = started.duration(to: .now)
        try await Task.sleep(for: .milliseconds(600))
        let counts = observer.stop()
        XCTAssertEqual(axFrontmost(app.pid), true)
        log.notice("current-space activation ms=\(Self.ms(activation), privacy: .public) frontmostChanges=\(counts.frontmostChanges, privacy: .public) dockWindowsAppeared=\(counts.dockWindowsAppeared, privacy: .public)")
        XCTAssertEqual(counts.dockWindowsAppeared, 0, "the system switcher must not appear")
    }

    // MARK: Helpers

    private func launch(_ url: URL) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        launched.append(app)
        try await poll("\(url.lastPathComponent) has a window", timeout: .seconds(8)) { self.axWindowCount(app.processIdentifier) > 0 }
        return app
    }

    private func launchFullscreenCapable() async throws -> (NSRunningApplication, AXUIElement)? {
        for path in Self.fullscreenCandidates where FileManager.default.fileExists(atPath: path) {
            let app = try await launch(URL(fileURLWithPath: path))
            if let window = axWindows(app.processIdentifier).first {
                var settable = DarwinBoolean(false)
                if AXUIElementIsAttributeSettable(window, "AXFullScreen" as CFString, &settable) == .success, settable.boolValue {
                    return (app, window)
                }
            }
            app.terminate()
            launched.removeAll { $0 == app }
        }
        return nil
    }

    /// The WindowServer rows of a pid: numbers only, never names.
    private func logRows(of pid: pid_t, label: String) {
        let info = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for row in info where (row[kCGWindowOwnerPID as String] as? Int) == Int(pid) {
            let bounds = (row[kCGWindowBounds as String]).flatMap { CGRect(dictionaryRepresentation: $0 as! CFDictionary) } ?? .zero
            let wid = CGWindowID(row[kCGWindowNumber as String] as? Int ?? 0)
            let spaces = OffSpaceDiagnostics.spaceIDs(of: wid).map { String(describing: $0) } ?? "?"
            let line = "wid=\(wid) layer=\(row[kCGWindowLayer as String] ?? 0) size=\(Int(bounds.width))x\(Int(bounds.height)) alpha=\(row[kCGWindowAlpha as String] ?? 0) onscreen=\(row[kCGWindowIsOnscreen as String] ?? false) spaces=\(spaces)"
            log.notice("rows[\(label, privacy: .public)] \(line, privacy: .public)")
        }
    }

    private func isOnscreen(_ wid: CGWindowID) -> Bool {
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return info.contains { ($0[kCGWindowNumber as String] as? Int) == Int(wid) }
    }

    private func info(_ app: NSRunningApplication) -> AppInfo {
        AppInfo(bundleID: app.bundleIdentifier ?? "", pid: app.processIdentifier, localizedName: app.localizedName ?? "")
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func axWindows(_ pid: pid_t) -> [AXUIElement] {
        (attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    private func axWindowCount(_ pid: pid_t) -> Int { axWindows(pid).count }

    private func axFrontmost(_ pid: pid_t) -> Bool? {
        attribute(AXUIElementCreateApplication(pid), kAXFrontmostAttribute) as? Bool
    }

    private func poll(_ what: String, timeout: Duration, until condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            if try await condition() { return }
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func ms(_ duration: Duration) -> String {
        let parts = duration.components
        return String(format: "%.0f", Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15)
    }
}

/// hkprobe's observers: Dock-owned on-screen windows not in the baseline are
/// the system switcher (layer 20, full-screen size); frontmost changes come
/// from NSWorkspace. Only owner name, layer and window number are read.
@MainActor
final class FlickerObserver {
    struct Counts { var dockWindowsAppeared = 0; var frontmostChanges = 0 }

    private var baseline: Set<CGWindowID> = []
    private var switcherVisible = false
    private var lastFrontmost: String?
    private var counts = Counts()
    private var timer: Timer?

    func start() {
        baseline = Set(dockWindows())
        lastFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            MainActor.assumeIsolated { self.poll() }
        }
    }

    func stop() -> Counts {
        timer?.invalidate()
        timer = nil
        poll()
        return counts
    }

    private func dockWindows() -> [CGWindowID] {
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return info.filter { ($0[kCGWindowOwnerName as String] as? String) == "Dock" }
            .compactMap { ($0[kCGWindowNumber as String] as? Int).map(CGWindowID.init) }
    }

    private func poll() {
        let extra = dockWindows().filter { !baseline.contains($0) }
        let visible = !extra.isEmpty
        if visible != switcherVisible {
            switcherVisible = visible
            if visible { counts.dockWindowsAppeared += 1 }
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let last = lastFrontmost, last != front { counts.frontmostChanges += 1 }
        lastFrontmost = front
    }
}
