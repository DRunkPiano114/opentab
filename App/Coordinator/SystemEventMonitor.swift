import AppKit

/// The system transitions after which the cache cannot be trusted or the
/// panel cannot stay where it is: sleep/wake, display topology, the active
/// Space, and fast user switching. Public notifications only (L15).
@MainActor
final class SystemEventMonitor {
    var onWake: (() -> Void)?
    var onScreensChanged: (() -> Void)?
    var onActiveSpaceChanged: (() -> Void)?
    var onSessionResigned: (() -> Void)?
    var onSessionResumed: (() -> Void)?

    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    func start() {
        stop()
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didWakeNotification) { $0.onWake?() }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.onActiveSpaceChanged?() }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.onSessionResigned?() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.onSessionResumed?() }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.onScreensChanged?() }
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (SystemEventMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        tokens.append((center, token))
    }
}
