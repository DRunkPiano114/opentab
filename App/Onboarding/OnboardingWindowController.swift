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
    /// The settings the flow reads its chords from and writes its choices to.
    private(set) var store: SettingsStore?
    /// Whether this Mac can take Cmd-Tab over at all.
    private(set) var takeoverAvailable = true
    /// True while the flow is up and the shortcuts step has not been
    /// confirmed. The app treats the takeover as not wanted meanwhile, so the
    /// stored Cmd-Tab default does not take over at the Accessibility step,
    /// one step before the sentence that says what Cmd-Tab replaces.
    var holdsTakeover = false
    /// Called whenever `holdsTakeover` changes.
    var onHoldChanged: (() -> Void)?

    private var window: NSWindow?

    var isActive: Bool { window != nil }

    func show(store: SettingsStore, takeoverAvailable: Bool) {
        guard window == nil else { return }
        self.store = store
        self.takeoverAvailable = takeoverAvailable
        model.mainHotKey = store.mainHotKey
        model.reverseHotKey = store.reverseHotKey
        model.searchHotKey = store.searchHotKey
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
