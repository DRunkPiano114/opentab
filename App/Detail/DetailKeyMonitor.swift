import AppKit
import OpenTabCore

/// The `Cmd+W` chord, and only while the app is active.
///
/// A local monitor is enough because it only runs in the search state: the app
/// is active, the panel is key, and the event is ours to consume. In the
/// navigation state the panel is a non-activating panel that never became key,
/// so a global monitor could observe the chord but not swallow it, and the
/// same `Cmd+W` would also reach the app in front and close one of its
/// windows. Nothing here is installed until the search state is entered.
@MainActor
final class DetailKeyMonitor {
    var onCloseSelected: (() -> Void)?

    private var monitor: Any?
    private let log = Log.make("keys")

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, Self.isCloseChord(event) else { return event }
            MainActor.assumeIsolated { self.onCloseSelected?() }
            return nil
        }
        log.debug("close chord monitor installed=\(self.monitor != nil, privacy: .public)")
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Command and nothing else: `Cmd+Shift+W` closes a whole window in most
    /// apps and is not this action.
    nonisolated static func isCloseChord(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "w"
    }
}
