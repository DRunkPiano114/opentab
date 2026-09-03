import AppKit
import OpenTabAX
import SwiftUI

/// Hosts the first-run flow. Alive only until the user finishes it, and the
/// app delegate waits for `onFinish` before putting anything else modal in
/// front of them.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    let model = OnboardingModel()
    /// Called once, when the flow ends.
    var onFinish: (() -> Void)?

    private var window: NSWindow?

    var isActive: Bool { window != nil }

    func show(hotKeys: (main: HotKeyBinding, reverse: HotKeyBinding, search: HotKeyBinding)) {
        guard window == nil else { return }
        model.mainHotKey = hotKeys.main
        model.reverseHotKey = hotKeys.reverse
        model.searchHotKey = hotKeys.search
        model.accessibilityGranted = AXTrust.isTrusted

        let view = OnboardingView(model: model,
                                  promptForAccessibility: { [weak self] in
                                      self?.model.markPrompted()
                                      AXTrust.prompt()
                                  },
                                  openAccessibilitySettings: {
                                      NSWorkspace.shared.open(SystemSettingsLinks.accessibility)
                                  },
                                  finish: { [weak self] in self?.finish() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "OpenTab"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func accessibilityChanged(_ granted: Bool) {
        model.accessibilityChanged(granted)
    }

    /// Dismissing the window counts as finishing: the flow is not shown
    /// again, and whatever it was holding back goes ahead. Without this a
    /// closed window would leave the app waiting on a flow that is gone.
    func windowWillClose(_ notification: Notification) {
        guard window != nil else { return }
        window = nil
        onFinish?()
    }

    /// Closing is the single exit; `windowWillClose` does the rest.
    private func finish() {
        window?.close()
    }
}
