import AppKit
import ApplicationServices
import OpenTabCore

/// Brings a window listed by `AXWindowSource` to the front.
///
/// AX calls run on the target pid's queue; AppKit calls hop to the main
/// thread. Success means the target app reports `kAXFrontmostAttribute`;
/// `kAXFocusedWindowAttribute` only says which of its windows is focused and
/// is reported, not required.
public final class AXWindowActivator: WindowActivator, Sendable {
    private static let pollInterval: Duration = .milliseconds(25)
    /// An activation request is asynchronous and can be dropped while the
    /// window server is still settling the raise, so it is repeated until the
    /// app answers frontmost or the deadline passes.
    private static let requestInterval: Duration = .milliseconds(200)

    private let source: AXWindowSource
    private let log = Log.make("activate")

    public init(source: AXWindowSource) {
        self.source = source
    }

    public func activate(_ key: WindowKey, deadline: ContinuousClock.Instant) async throws {
        guard let cached = source.cachedElement(for: key) else {
            throw AXActivationError.unknownWindow(key)
        }
        let pid = cached.pid
        let element = cached.element

        try await source.perform(on: pid) {
            try AXWindowSource.checkDeadline(deadline)
            let minimized = (AXRead.value(element, kAXMinimizedAttribute).value as? Bool) ?? false
            if minimized {
                AXUIElementSetAttributeValue(element.raw, kAXMinimizedAttribute as CFString, false as CFBoolean)
            }
        }
        await MainActor.run {
            if let app = NSRunningApplication(processIdentifier: pid), app.isHidden {
                app.unhide()
            }
        }
        _ = try await source.perform(on: pid) {
            AXUIElementPerformAction(element.raw, kAXRaiseAction as CFString)
        }

        let started = ContinuousClock.now
        var lastRequest = started
        await Self.requestActivation(of: pid)
        while true {
            let frontmost = try await source.perform(on: pid) { self.source.isFrontmost(pid: pid) }
            if frontmost { break }
            guard ContinuousClock.now + Self.pollInterval < deadline else {
                throw AXActivationError.unconfirmed
            }
            if ContinuousClock.now - lastRequest >= Self.requestInterval {
                await Self.requestActivation(of: pid)
                lastRequest = .now
            }
            try await Task.sleep(for: Self.pollInterval)
        }

        let targetID: CGWindowID? = if case .cg(let id) = key { id } else { nil }
        let windowFocused = try await source.perform(on: pid) {
            guard let focused = self.source.focusedWindow(pid: pid) else { return false }
            if focused == element { return true }
            guard let targetID else { return false }
            return self.source.windowID(of: focused) == targetID
        }
        log.notice("""
            frontmost pid=\(pid, privacy: .public) \
            after=\(Self.milliseconds(started.duration(to: .now)), format: .fixed(precision: 0), privacy: .public)ms \
            windowFocused=\(windowFocused, privacy: .public)
            """)
    }

    @MainActor
    private static func requestActivation(of pid: pid_t) {
        _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
