import AppKit
import ApplicationServices
import OpenTabAX
import OpenTabCore
import os

/// Activates windows listed by `OffSpaceWindowSource`. Windows the AX source
/// knows go through `AXWindowActivator` unchanged; a window reached only
/// through a remote token runs the same sequence on its token element:
/// un-minimize, unhide, `AXRaise`, activate the app, and judge success by the
/// app's own `kAXFrontmostAttribute`. No SkyLight.
public final class OffSpaceWindowActivator: WindowActivator, Sendable {
    private static let pollInterval: Duration = .milliseconds(25)
    private static let requestInterval: Duration = .milliseconds(200)

    private let source: OffSpaceWindowSource
    private let base: AXWindowActivator
    private let log = Log.make("ws-activate")

    public init(source: OffSpaceWindowSource) {
        self.source = source
        self.base = AXWindowActivator(source: source.base)
    }

    public func activate(_ key: WindowKey, deadline: ContinuousClock.Instant) async throws {
        do {
            try await base.activate(key, deadline: deadline)
            return
        } catch AXActivationError.unknownWindow {
            // Fall through to the token element, if there is one.
        }
        guard let reached = source.reachedElement(for: key) else {
            throw AXActivationError.unknownWindow(key)
        }
        let pid = reached.pid
        let element = reached.element
        guard case .cg(let targetID) = key else { throw AXActivationError.unknownWindow(key) }

        try await source.perform(on: pid) {
            if ContinuousClock.now >= deadline { throw AXSourceError.deadlineExceeded }
            if (AXReader.value(element, kAXMinimizedAttribute) as? Bool) ?? false {
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
            let frontmost = try await source.perform(on: pid) { AXReader.isFrontmost(pid: pid) }
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

        let windowFocused = try await source.perform(on: pid) { AXReader.focusedWindowID(pid: pid) == targetID }
        log.notice("""
            token window frontmost pid=\(pid, privacy: .public) wid=\(targetID, privacy: .public) \
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
