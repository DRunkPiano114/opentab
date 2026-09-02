import AppKit
import ApplicationServices
import OpenTabCore

/// Brings a window listed by `AXWindowSource` to the front.
///
/// AX calls run on the target pid's queue; AppKit calls hop to the main
/// thread. Success is read back from `kAXFocusedWindowAttribute` (L2).
public final class AXWindowActivator: WindowActivator, Sendable {
    private static let pollInterval: Duration = .milliseconds(25)

    private let source: AXWindowSource

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
        await MainActor.run {
            _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        }

        let targetID: CGWindowID? = if case .cg(let id) = key { id } else { nil }
        while true {
            let confirmed = try await source.perform(on: pid) {
                guard let focused = self.source.focusedWindow(pid: pid) else { return false }
                if focused == element { return true }
                guard let targetID else { return false }
                return self.source.windowID(of: focused) == targetID
            }
            if confirmed { return }
            guard ContinuousClock.now + Self.pollInterval < deadline else {
                throw AXActivationError.unconfirmed
            }
            try await Task.sleep(for: Self.pollInterval)
        }
    }
}
