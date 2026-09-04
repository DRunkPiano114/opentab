import AppKit
import ApplicationServices
import OpenTabAX
import OpenTabCore
import XCTest

@testable import OpenTab

/// Frame matching is exercised as a pure function; the cascade itself is run
/// against a real Calculator launched in the background, which needs the
/// Accessibility grant the installed app carries.
@MainActor
final class WindowResolverTests: XCTestCase {
    private static let calculatorURL = URL(fileURLWithPath: "/System/Applications/Calculator.app")
    private static let frame = CGRect(x: 100, y: 200, width: 300, height: 400)

    private var previous: NSRunningApplication?
    private var calculator: NSRunningApplication?

    override func tearDown() async throws {
        if let calculator {
            calculator.terminate()
            // The next test launches Calculator again, and opening it while the
            // old instance is still dying fails with procNotFound.
            try await poll("calculator exited", timeout: .seconds(5)) { calculator.isTerminated }
        }
        calculator = nil
        if let previous {
            _ = previous.activate(options: [])
            try? await poll("previous app frontmost again", timeout: .seconds(2)) {
                self.axFrontmost(previous.processIdentifier) == true
            }
        }
        previous = nil
    }

    // MARK: Frame matching

    func testFrameMatchIsExactlyOneRow() {
        let rows: [WindowResolver.CGRow] = [
            (id: 11, bounds: Self.frame),
            (id: 12, bounds: Self.frame.offsetBy(dx: 500, dy: 0)),
        ]
        XCTAssertEqual(WindowResolver.match(frame: Self.frame, rows: rows), .success(11))
    }

    func testFrameMatchRejectsTwoRowsWithTheSameBounds() {
        let rows: [WindowResolver.CGRow] = [(id: 11, bounds: Self.frame), (id: 12, bounds: Self.frame)]
        XCTAssertEqual(WindowResolver.match(frame: Self.frame, rows: rows), .failure(.frameAmbiguous))
    }

    func testFrameMatchReportsNoCandidate() {
        let rows: [WindowResolver.CGRow] = [(id: 11, bounds: Self.frame.offsetBy(dx: 500, dy: 0))]
        XCTAssertEqual(WindowResolver.match(frame: Self.frame, rows: rows), .failure(.cgFallbackFailed))
    }

    func testFrameMatchToleratesSubpointDrift() {
        let drifted = Self.frame.offsetBy(dx: 0.5, dy: -0.5)
        XCTAssertEqual(WindowResolver.match(frame: Self.frame, rows: [(id: 11, bounds: drifted)]), .success(11))
    }

    func testFrameMatchRejectsTwoPointDrift() {
        let drifted = Self.frame.offsetBy(dx: 2, dy: 0)
        XCTAssertEqual(WindowResolver.match(frame: Self.frame, rows: [(id: 11, bounds: drifted)]),
                       .failure(.cgFallbackFailed))
    }

    // MARK: The cascade against a real app

    func testResolvesCalculatorWindowWithoutTheBridge() async throws {
        try await assertResolvesCalculator(directBridge: false)
    }

    func testResolvesThroughTheBridgeWhenAvailable() async throws {
        try await assertResolvesCalculator(directBridge: true)
    }

    func testStoppedAppTimesOutWithinDeadline() async throws {
        let app = try await launchCalculator()
        let window = try await unbridgedWindow(of: app)
        // A stopped process answers no AX message; every read costs the full
        // messaging timeout.
        kill(app.pid, SIGSTOP)
        defer { kill(app.pid, SIGCONT) }

        let clock = ContinuousClock()
        let started = clock.now
        let resolved = await WindowResolver(directBridge: false).resolve(window, deadline: .now + .milliseconds(300))
        let elapsed = clock.now - started

        XCTAssertNil(resolved)
        XCTAssertLessThan(elapsed, .milliseconds(500))
        print("stopped app: \(elapsed)")
    }

    // MARK: Helpers

    private func assertResolvesCalculator(directBridge: Bool) async throws {
        let app = try await launchCalculator()
        let window = try await unbridgedWindow(of: app)

        let clock = ContinuousClock()
        let started = clock.now
        let resolver = WindowResolver(directBridge: directBridge)
        var resolved = await resolver.resolve(window, deadline: .now + .seconds(1))
        // A window still in its launch animation reports a frame to AX that
        // the WindowServer has not caught up with yet; the frame fallback
        // legitimately declines then, so it gets a moment to settle.
        var attempts = 1
        while resolved == nil, attempts < 10 {
            try await Task.sleep(for: .milliseconds(100))
            resolved = await resolver.resolve(window, deadline: .now + .seconds(1))
            attempts += 1
        }
        let elapsed = clock.now - started

        let expected = try await bridgedWindowID(of: app)
        XCTAssertEqual(resolved, expected)
        print("directBridge=\(directBridge): \(elapsed) attempts=\(attempts)")
    }

    /// The one Calculator window as the AX source reports it with the window id
    /// bridge switched off, so its key is an `.ax` key for the resolver to lift.
    private func unbridgedWindow(of app: AppInfo) async throws -> WindowSnapshot {
        let snapshots = try await AXWindowSource(windowIDBridgeEnabled: false)
            .snapshot(of: app, deadline: .now + .seconds(2))
        let window = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshots.count, 1, "the expected id below assumes a single Calculator window")
        guard case .ax = window.key else {
            throw XCTSkip("the AX source keyed the window as \(window.key) with the bridge disabled")
        }
        return window
    }

    private func bridgedWindowID(of app: AppInfo) async throws -> UInt32 {
        let snapshots = try await AXWindowSource(windowIDBridgeEnabled: true)
            .snapshot(of: app, deadline: .now + .seconds(2))
        guard case .cg(let id) = try XCTUnwrap(snapshots.first).key else {
            throw XCTSkip("the window id bridge is unavailable in this build")
        }
        return id
    }

    private func launchCalculator() async throws -> AppInfo {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs the Accessibility grant")
        // The app sets this at launch; the test host returns early from
        // `applicationDidFinishLaunching`, so without it a stopped app would
        // hold a read for the ~1.5s default instead of 150ms.
        AXConfiguration.configureGlobalTimeout()
        previous = NSWorkspace.shared.frontmostApplication
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let running = try await NSWorkspace.shared.openApplication(at: Self.calculatorURL, configuration: configuration)
        calculator = running
        try await poll("calculator has a window", timeout: .seconds(5)) {
            self.windowCount(running.processIdentifier) > 0
        }
        return AppInfo(bundleID: running.bundleIdentifier ?? "", pid: running.processIdentifier,
                       localizedName: running.localizedName ?? "")
    }

    private func axFrontmost(_ pid: pid_t) -> Bool? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, &value)
        return error == .success ? (value as? Bool) : nil
    }

    private func windowCount(_ pid: pid_t) -> Int {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success else {
            return 0
        }
        return (value as? [AXUIElement])?.count ?? 0
    }

    private func poll(_ what: String, timeout: Duration, until condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            if try await condition() { return }
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
