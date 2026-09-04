import AppKit
import ApplicationServices
import OpenTabAX
import OpenTabCore
import XCTest

/// Drives the production activator against another process from this
/// accessory, never-active app, and judges the result the way the app does:
/// the target's own `kAXFrontmostAttribute`. Needs the Accessibility
/// grant the installed app carries; the frontmost app is handed back at the
/// end.
@MainActor
final class ActivationTests: XCTestCase {
    private static let calculatorURL = URL(fileURLWithPath: "/System/Applications/Calculator.app")

    private var previous: NSRunningApplication!
    private var calculator: NSRunningApplication!

    override func setUp() async throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs the Accessibility grant")
        previous = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        calculator = try await NSWorkspace.shared.openApplication(at: Self.calculatorURL, configuration: configuration)
        try await poll("calculator has a window", timeout: .seconds(5)) {
            self.windowCount(self.calculator.processIdentifier) > 0
        }
    }

    override func tearDown() async throws {
        calculator?.terminate()
        if let previous {
            _ = previous.activate(options: [])
            try? await poll("previous app frontmost again", timeout: .seconds(2)) {
                self.axFrontmost(previous.processIdentifier) == true
            }
        }
    }

    func testActivatorMakesTargetAppFrontmost() async throws {
        let pid = calculator.processIdentifier
        let source = AXWindowSource()
        let app = AppInfo(bundleID: calculator.bundleIdentifier ?? "", pid: pid,
                          localizedName: calculator.localizedName ?? "")
        let snapshots = try await source.snapshot(of: app, deadline: .now + .seconds(2))
        let window = try XCTUnwrap(snapshots.first)
        XCTAssertNotEqual(axFrontmost(pid), true, "calculator must start in the background")

        let activator = AXWindowActivator(source: source)
        let started = ContinuousClock.now
        try await activator.activate(window.key, deadline: .now + .milliseconds(500))
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(500))
        XCTAssertEqual(axFrontmost(pid), true)

        try await poll("NSWorkspace catches up", timeout: .seconds(1)) {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, pid)
    }

    func testActivatorReportsUnconfirmedWhenAppNeverComesFront() async throws {
        let pid = calculator.processIdentifier
        let source = AXWindowSource()
        let app = AppInfo(bundleID: calculator.bundleIdentifier ?? "", pid: pid,
                          localizedName: calculator.localizedName ?? "")
        let snapshots = try await source.snapshot(of: app, deadline: .now + .seconds(2))
        let key = try XCTUnwrap(snapshots.first).key
        // A stopped process cannot answer AX at all, so it can never confirm.
        kill(pid, SIGSTOP)
        defer { kill(pid, SIGCONT) }
        do {
            try await AXWindowActivator(source: source).activate(key, deadline: .now + .milliseconds(300))
            XCTFail("expected unconfirmed")
        } catch AXActivationError.unconfirmed {
        }
    }

    // MARK: Helpers

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
